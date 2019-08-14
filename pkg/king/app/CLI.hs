{-# OPTIONS_GHC -Werror -Wall #-}
{-# LANGUAGE CPP #-}

module CLI (parseArgs, Cmd(..), New(..), Run(..), Opts(..)) where

import ClassyPrelude
import Options.Applicative
import Options.Applicative.Help.Pretty

import Data.Word          (Word16)
import System.Environment (getProgName)

--------------------------------------------------------------------------------

data Opts = Opts
    { oQuiet     :: Bool
    , oHashless  :: Bool
    , oExit      :: Bool
    , oDryRun    :: Bool
    , oVerbose   :: Bool
    , oAmesPort  :: Maybe Word16
    , oProf      :: Bool
    , oCollectFx :: Maybe FilePath
    }
  deriving (Show)

data New = New
    { nPillPath  :: FilePath
    , nShipAddr  :: Text
    , nPierPath  :: FilePath
    , nArvoDir   :: Maybe FilePath
    , nBootFake  :: Bool
    , nLocalhost :: Bool
    }
  deriving (Show)

data Run = Run
    { rPierPath :: FilePath
    }
  deriving (Show)

data Cmd
    = CmdNew New Opts
    | CmdRun Run Opts
    | CmdTry FilePath
  deriving (Show)

--------------------------------------------------------------------------------

headNote :: String -> Doc
headNote _version = string $ intercalate "\n"
  [ "Urbit: a personal server operating function"
  , "https://urbit.org"
  , "Version " <> VERSION_king
  ]

footNote :: String -> Doc
footNote exe = string $ intercalate "\n"
  [ "Development Usage:"
  , "  To create a development ship, use a fakezod:"
  , "    $ " <>exe<> " new zod /path/to/pill -F zod -A arvo/folder"
  , ""
  , "Simple Usage: "
  , "  $ " <>exe<> " new pier <my-comet> to create a comet (anonymous urbit)"
  , "  $ " <>exe<> " new pier <my-planet> -k <my-key-file> if you own a planet"
  , "  $ " <>exe<> " run <myplanet or mycomet> to restart an existing urbit"
  , ""
  , "For more information about developing on urbit, see:"
  , "  https://github.com/urbit/urbit/blob/master/CONTRIBUTING.md"
  ]

--------------------------------------------------------------------------------

parseArgs :: IO Cmd
parseArgs = do
    nm <- getProgName

    let p = prefs $ showHelpOnError
                 <> showHelpOnEmpty
                 <> columns 80

    let o = info (cmd <**> helper)
              $ progDesc "Start an existing Urbit or boot a new one."
             <> headerDoc (Just $ headNote "0.9001.0")
             <> footerDoc (Just $ footNote nm)
             <> fullDesc

    customExecParser p o

--------------------------------------------------------------------------------

run :: Parser Run
run = do
    rPierPath <- strArgument (metavar "PIER" <> help "Path to pier")
    pure Run{..}

new :: Parser New
new = do
    nPierPath <- strArgument (metavar "PIER" <> help "Path to pier")
    nPillPath <- strArgument (metavar "PILL" <> help "Path to pill file")
    nShipAddr <- strArgument (metavar "SHIP" <> help "Ship address")

    nLocalhost <- switch $ short 'L'
                        <> long "local"
                        <> help "Localhost-only networking"

    nBootFake <- switch $ short 'F'
                       <> long "fake"
                       <> help "Create a fake ship"

    nArvoDir <- option auto $ metavar "ARVO"
                           <> short 'A'
                           <> value Nothing
                           <> help "Initial Arvo filesystem"

    pure New{..}

opts :: Parser Opts
opts = do
    oAmesPort <- option auto $ metavar "PORT"
                            <> short 'p'
                            <> help "Ames port number"
                            <> value Nothing

    oHashless <- switch (short 'S' <> help "Disable battery hashing")
    oQuiet    <- switch (short 'q' <> help "Quiet")
    oVerbose  <- switch (short 'v' <> help "Verbose")
    oExit     <- switch (short 'x' <> help "Exit immediatly")
    oDryRun   <- switch (short 'N' <> help "Dry run -- Don't persist")
    oProf     <- switch (short 'p' <> help "Enable profiling")

    oCollectFx <- option auto $ metavar "FXDIR"
                             <> long "collect-fx"
                             <> help "Write effects to disk for debugging"
                             <> value Nothing

    pure (Opts{..})

cmd :: Parser Cmd
cmd = subparser
        ( (command "new" $ info (newShip <**> helper)
                         $ progDesc "Boot a new ship")
       <> (command "run" $ info (runShip <**> helper)
                         $ progDesc "Run an existing ship")
       <> (command "try" $ info (tryShip <**> helper)
                         $ progDesc "Run development test flow")
        )
  where
    runShip = CmdRun <$> run <*> opts
    newShip = CmdNew <$> new <*> opts
    tryShip = CmdTry <$> strArgument (metavar "PIER" <> help "Path to pier")
