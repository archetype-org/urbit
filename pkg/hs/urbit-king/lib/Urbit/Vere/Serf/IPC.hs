{-
|%
::  +writ: from king to serf
::
+$  gang  (unit (set ship))
+$  writ
  $%  $:  %live
          $%  [%exit cod=@]
              [%save eve=@]
              [%pack eve=@]
      ==  ==
      [%peek now=date lyc=gang pat=path]
      [%play eve=@ lit=(list ?((pair date ovum) *))]
      [%work job=(pair date ovum)]
  ==
::  +plea: from serf to king
::
+$  plea
  $%  [%live ~]
      [%ripe [pro=@ hon=@ nok=@] eve=@ mug=@]
      [%slog pri=@ ?(cord tank)]
      [%peek dat=(unit (cask))]
      $:  %play
          $%  [%done mug=@]
              [%bail eve=@ mug=@ dud=goof]
      ==  ==
      $:  %work
          $%  [%done eve=@ mug=@ fec=(list ovum)]
              [%swap eve=@ mug=@ job=(pair date ovum) fec=(list ovum)]
              [%bail lud=(list goof)]
      ==  ==
  ==
-}

module Urbit.Vere.Serf.IPC
  ( Serf
  , Config(..)
  , PlayBail(..)
  , Flag(..)
  , RunError(..)
  , RunInput(..)
  , RunOutput(..)
  , start
  , serfLastEventBlocking
  , shutdown
  , snapshot
  , bootSeq
  , replay
  , running
  )
where

import Urbit.Prelude hiding ((<|))

import Data.Bits
import Data.Conduit
import System.Process
import Urbit.Arvo
import Urbit.Vere.Pier.Types hiding (Work)

import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr           (castPtr)
import Foreign.Storable      (peek, poke)
import RIO.Prelude           (decodeUtf8Lenient)
import System.Posix.Signals  (sigKILL, signalProcess)
import Urbit.Time            (Wen)

import qualified Data.ByteString        as BS
import qualified Data.ByteString.Unsafe as BS
import qualified System.IO.Error        as IO
import qualified Urbit.Time             as Time


-- IPC Types -------------------------------------------------------------------

type Gang = Maybe (HoonSet Ship)

type Goof = (Term, [Tank])

data Live
  = LExit Atom -- exit status code
  | LSave EventId
  | LPack EventId
 deriving (Show)

type PlayBail = (EventId, Mug, Goof)

data Play
  = PDone Mug
  | PBail PlayBail
 deriving (Show)

data Work
  = WDone EventId Mug [Ef]
  | WSwap EventId Mug (Wen, Noun) [Ef]
  | WBail [Goof]
 deriving (Show)

data Writ
  = WLive Live
  | WPeek Wen Gang Path
  | WPlay EventId [Noun]
  | WWork Wen Ev
 deriving (Show)

data RipeInfo = RipeInfo
  { riProt :: Atom
  , riHoon :: Atom
  , riNock :: Atom
  }
 deriving (Show)

data SerfState = SerfState
  { ssLast :: EventId
  , ssHash :: Mug
  }
 deriving (Show)

data SerfInfo = SerfInfo
  { siRipe :: RipeInfo
  , siStat :: SerfState
  }
 deriving (Show)

type Slog = (Atom, Tank)

data Plea
  = PLive ()
  | PRipe SerfInfo
  | PSlog Slog
  | PPeek (Maybe (Term, Noun))
  | PPlay Play
  | PWork Work
 deriving (Show)

deriveNoun ''Live
deriveNoun ''Play
deriveNoun ''Work
deriveNoun ''Writ
deriveNoun ''RipeInfo
deriveNoun ''SerfState
deriveNoun ''SerfInfo
deriveNoun ''Plea


-- Serf API Types --------------------------------------------------------------

data Serf = Serf
  { serfSend :: Handle
  , serfRecv :: Handle
  , serfProc :: ProcessHandle
  , serfSlog :: Slog -> IO ()
  , serfLock :: MVar (Either SomeException SerfState)
  }

data Flag
  = DebugRam
  | DebugCpu
  | CheckCorrupt
  | CheckFatal
  | Verbose
  | DryRun
  | Quiet
  | Hashless
  | Trace
 deriving (Eq, Ord, Show, Enum, Bounded)

data Config = Config
  { scSerf :: FilePath       --  Where is the urbit-worker executable?
  , scPier :: FilePath       --  Where is the pier directory?
  , scFlag :: [Flag]         --  Serf execution flags.
  , scSlog :: Slog -> IO ()  --  What to do with slogs?
  , scStdr :: Text -> IO ()  --  What to do with lines from stderr?
  , scDead :: IO ()          --  What to do when the serf process goes down?
  }

data RunError
  = RunBail [Goof]
  | RunSwap EventId Mug Wen Noun [Ef]

data RunInput
  = RunSnap
  | RunPack
  | RunPeek Wen Gang Path (Maybe (Term, Noun) -> IO ())
  | RunWork Ev (RunError -> IO ())

data RunOutput = RunOutput EventId Mug Wen Noun [Ef]


-- Exceptions ------------------------------------------------------------------

data SerfExn
--  = BadComputeId EventId WorkResult
--  | BadReplacementId EventId ReplacementEv
--  | UnexpectedPlay EventId (EventId, Mug)
    = UnexpectedPlea Plea Text
    | BadPleaAtom Atom
    | BadPleaNoun Noun [Text] Text
--  | ReplacedEventDuringReplay EventId ReplacementEv
--  | ReplacedEventDuringBoot   EventId ReplacementEv
--  | EffectsDuringBoot         EventId FX
    | SerfConnectionClosed
--  | UnexpectedPleaOnNewShip Plea
--  | InvalidInitialPlea Plea
  deriving (Show, Exception)


-- Access Current Serf State ---------------------------------------------------

serfLastEventBlocking :: Serf -> IO EventId
serfLastEventBlocking Serf{serfLock} = readMVar serfLock >>= \case
  Left err -> throwIO err
  Right ss -> pure (ssLast ss)


-- Low Level IPC Functions -----------------------------------------------------

fromRightExn :: (Exception e, MonadIO m) => Either a b -> (a -> e) -> m b
fromRightExn (Left m)  exn = throwIO (exn m)
fromRightExn (Right x) _   = pure x

-- TODO Support Big Endian
sendLen :: Serf -> Int -> IO ()
sendLen s i = do
  w <- evaluate (fromIntegral i :: Word64)
  withWord64AsByteString w (hPut (serfSend s))
 where
  withWord64AsByteString :: Word64 -> (ByteString -> IO a) -> IO a
  withWord64AsByteString w k = alloca $ \wp -> do
    poke wp w
    bs <- BS.unsafePackCStringLen (castPtr wp, 8)
    k bs

sendBytes :: Serf -> ByteString -> IO ()
sendBytes s bs = handle onIOError $ do
  sendLen s (length bs)
  hPut (serfSend s) bs
  hFlush (serfSend s)
 where
  onIOError :: IOError -> IO ()
  onIOError = const (throwIO SerfConnectionClosed)  --  TODO call death callback?

recvBytes :: Serf -> Word64 -> IO ByteString
recvBytes serf = BS.hGet (serfRecv serf) . fromIntegral

recvLen :: Serf -> IO Word64
recvLen w = do
  bs <- BS.hGet (serfRecv w) 8
  case length bs of
    8 -> BS.unsafeUseAsCString bs (peek @Word64 . castPtr)
    _ -> throwIO SerfConnectionClosed  -- TODO kill worker process and call the death callback.

recvResp :: Serf -> IO ByteString
recvResp serf = do
  len <- recvLen serf
  recvBytes serf len


-- Send Writ / Recv Plea -------------------------------------------------------

sendWrit :: Serf -> Writ -> IO ()
sendWrit s = sendBytes s . jamBS . toNoun

recvPlea :: Serf -> IO Plea
recvPlea w = do
  b <- recvResp w
  n <- fromRightExn (cueBS b) (const $ BadPleaAtom $ bytesAtom b)
  p <- fromRightExn (fromNounErr @Plea n) (\(p, m) -> BadPleaNoun n p m)
  pure p

recvPleaHandlingSlog :: Serf -> IO Plea
recvPleaHandlingSlog serf = loop
 where
  loop = recvPlea serf >>= \case
    PSlog info -> serfSlog serf info >> loop
    other      -> pure other


-- Higher-Level IPC Functions --------------------------------------------------

recvRipe :: Serf -> IO SerfInfo
recvRipe serf = recvPleaHandlingSlog serf >>= \case
  PRipe ripe -> pure ripe
  plea       -> throwIO (UnexpectedPlea plea "expecting %play")

recvPlay :: Serf -> IO Play
recvPlay serf = recvPleaHandlingSlog serf >>= \case
  PPlay play -> pure play
  plea       -> throwIO (UnexpectedPlea plea "expecting %play")

recvLive :: Serf -> IO ()
recvLive serf = recvPleaHandlingSlog serf >>= \case
  PLive () -> pure ()
  plea     -> throwIO (UnexpectedPlea plea "expecting %live")

recvWork :: Serf -> IO Work
recvWork serf = do
  recvPleaHandlingSlog serf >>= \case
    PWork work -> pure work
    plea       -> throwIO (UnexpectedPlea plea "expecting %work")

recvPeek :: Serf -> IO (Maybe (Term, Noun))
recvPeek serf = do
  recvPleaHandlingSlog serf >>= \case
    PPeek peek -> pure peek
    plea       -> throwIO (UnexpectedPlea plea "expecting %peek")


-- Request-Response Points -- These don't touch the lock -----------------------

sendSnapshotRequest :: Serf -> EventId -> IO ()
sendSnapshotRequest serf eve = do
  sendWrit serf (WLive $ LSave eve)
  recvLive serf

sendCompactRequest :: Serf -> EventId -> IO ()
sendCompactRequest serf eve = do
  sendWrit serf (WLive $ LPack eve)
  recvLive serf

sendScryRequest :: Serf -> Wen -> Gang -> Path -> IO (Maybe (Term, Noun))
sendScryRequest serf w g p = do
  sendWrit serf (WPeek w g p)
  recvPeek serf

sendShutdownRequest :: Serf -> Atom -> IO ()
sendShutdownRequest serf exitCode = do
  sendWrit serf (WLive $ LExit exitCode)
  pure ()


-- Serf Usage Flows ------------------------------------------------------------

compileFlags :: [Flag] -> Word
compileFlags = foldl' (\acc flag -> setBit acc (fromEnum flag)) 0

readStdErr :: Handle -> (Text -> IO ()) -> IO () -> IO ()
readStdErr h onLine onClose = loop
 where
  loop = do
    IO.tryIOError (BS.hGetLine h >>= onLine . decodeUtf8Lenient) >>= \case
      Left exn -> onClose
      Right () -> loop

start :: Config -> IO (Serf, SerfInfo)
start (Config exePax pierPath flags onSlog onStdr onDead) = do
  (Just i, Just o, Just e, p) <- createProcess pSpec
  void $ async (readStdErr e onStdr onDead)
  vLock <- newEmptyMVar
  let serf = Serf i o p onSlog vLock
  info <- recvRipe serf
  putMVar vLock (Right $ siStat info)
  pure (serf, info)
 where
  diskKey = ""
  config  = show (compileFlags flags)
  args    = [pierPath, diskKey, config]
  pSpec   = (proc exePax args) { std_in  = CreatePipe
                               , std_out = CreatePipe
                               , std_err = CreatePipe
                               }

withSerfLock
  :: MonadIO m
  => (m (SerfState, a) -> m (Either SomeException (SerfState, a)))
  -> Serf
  -> (SerfState -> m (SerfState, a))
  -> m a
withSerfLock tryGen s f = do
  ss <- takeLock
  tryGen (f ss) >>= \case
    Left e -> do
      io (forceKillSerf s)
      putMVar (serfLock s) (Left e)
      throwIO e
    Right (ss', x) -> do
      putMVar (serfLock s) (Right ss')
      pure x
 where
  takeLock = do
    takeMVar (serfLock s) >>= \case
      Left exn -> putMVar (serfLock s) (Left exn) >> throwIO exn
      Right ss -> pure ss

snapshot :: HasLogFunc e => Serf -> RIO e ()
snapshot serf =
  withSerfLock try serf \ss -> do
    io (sendSnapshotRequest serf (ssLast ss))
    pure (ss, ())

shutdown :: HasLogFunc e => Serf -> RIO e ()
shutdown serf = do
  race_ (wait2sec >> forceKill) $ do
    logTrace "Getting current serf state (taking lock, might block if in use)."
    finalState <- takeMVar (serfLock serf)
    logTrace "Got serf state (and took lock). Requesting shutdown."
    io (sendShutdownRequest serf 0)
    logTrace "Sent shutdown request. Waiting for process to die."
    io $ waitForProcess (serfProc serf)
    logTrace "RIP Serf process."
 where
  wait2sec = threadDelay 2_000_000
  forceKill = do
    logTrace "Serf taking too long to go down, kill with fire (SIGTERM)."
    io (forceKillSerf serf)
    logTrace "Serf process killed with SIGTERM."

forceKillSerf :: Serf -> IO ()
forceKillSerf serf = do
  getPid (serfProc serf) >>= \case
    Nothing  -> pure ()
    Just pid -> do
      io $ signalProcess sigKILL pid
      io $ void $ waitForProcess (serfProc serf)

bootSeq :: Serf -> [Noun] -> IO (Maybe PlayBail)  --  TODO should this be an exception?
bootSeq serf@Serf{..} seq = do
  withSerfLock try serf \ss -> do
    recvPlay serf >>= \case
      PBail bail   -> pure (ss, Just bail)
      PDone newMug -> pure (SerfState (fromIntegral $ length seq) newMug, Nothing)

{-
  TODO Take advantage of IPC support for batching.
  TODO Maybe take snapshots
-}
replay
  :: forall m
   . (MonadUnliftIO m, MonadIO m)
  => Serf
  -> ConduitT Noun Void m (Maybe PlayBail)
replay serf = do
  withSerfLock tryC serf \ss -> do
    (r, ss') <- loop ss
    pure (ss', r)
 where
  loop :: SerfState -> ConduitT Noun Void m (Maybe PlayBail, SerfState)
  loop (SerfState lastEve lastMug) = await >>= \case
    Nothing -> pure (Nothing, SerfState lastEve lastMug)
    Just ev -> do
      let newEve = lastEve + 1
      io $ sendWrit serf (WPlay newEve [ev])
      io (recvPlay serf) >>= \case
        PBail bail   -> pure (Just bail, SerfState lastEve lastMug)
        PDone newMug -> loop (SerfState newEve newMug)

{-
  TODO *we* should probably kill the serf on exception?
  TODO callbacks on snapshot and compaction?
  TODO Take advantage of async IPC to fill pipe with more than one thing.
-}
running
  :: forall m
   . (MonadIO m, MonadUnliftIO m)
  => Serf
  -> (Maybe RunInput -> IO ())
  -> ConduitT RunInput RunOutput m ()
running serf notice = do
  withSerfLock tryC serf $ \SerfState{..} -> do
    newState <- loop ssHash ssLast
    pure (newState, ())
 where
  loop :: Mug -> EventId -> ConduitT RunInput RunOutput m SerfState
  loop mug eve = do
    io (notice Nothing)
    nex <- await
    io (notice nex)
    nex & \case
      Nothing -> do
        pure $ SerfState eve mug
      Just RunSnap -> do
        io (sendSnapshotRequest serf eve)
        loop mug eve
      Just RunPack -> do
        io (sendCompactRequest serf eve)
        loop mug eve
      Just (RunPeek wen gang pax act) -> do
        io (sendScryRequest serf wen gang pax >>= act)
        loop mug eve
      Just (RunWork evn err) -> do
        wen <- io Time.now
        io (sendWrit serf (WWork wen evn))
        io (recvWork serf) >>= \case
          WDone eid hash fx -> do
            yield (RunOutput eid hash wen (toNoun evn) fx)
            loop hash eid
          WSwap eid hash (wen, noun) fx -> do
            io $ err (RunSwap eid hash wen noun fx)
            yield (RunOutput eid hash wen noun fx)
            loop hash eid
          WBail goofs -> do
            io $ err (RunBail goofs)
            loop mug eve
