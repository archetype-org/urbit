import React, { useRef, SyntheticEvent } from "react";
import { Box, Center } from "@tlon/indigo-react";
import { Sidebar } from "./lib/Sidebar";
import ErrorBoundary from "../../../components/ErrorBoundary";
import { Notebooks } from "../../../types/publish-update";
import { SelectedGroup } from "../../../types/local-update";
import { Rolodex } from "../../../types/contact-update";
import { Invites } from "../../../types/invite-update";
import GlobalApi from "../../../api/global";
import { Associations } from "../../../types/metadata-update";
import { RouteComponentProps } from "react-router-dom";

type SkeletonProps = RouteComponentProps<{
  ship?: string;
  notebook?: string;
  noteId?: string;
}> & {
  notebooks: Notebooks;
  invites: Invites;
  associations: Associations;
  selectedGroups: SelectedGroup[];
  contacts: Rolodex;
  api: GlobalApi;
  children: React.ReactNode;
};

export function Skeleton(props: SkeletonProps) {
  const { api, notebooks } = props;
  const { ship, notebook, noteId } = props.match.params;

  const path =
    (ship &&
      notebook &&
      `${props.match.params.ship}/${props.match.params.notebook}`) ||
    undefined;

  const onScroll = (e: SyntheticEvent<HTMLDivElement>) => {
    const { scrollHeight, scrollTop, clientHeight } = e.target;
    const distanceFromBottom = scrollHeight - scrollTop - clientHeight;
    if (noteId && notebook && ship) {
      const note = notebooks?.[ship]?.[notebook]?.notes?.[noteId];
      if (!note || !note.comments) {
        return;
      }
      const loadedComments = note.comments?.length;
      const fullyLoaded = note["num-comments"] === loadedComments;
      if (distanceFromBottom < 40) {
        if (!fullyLoaded) {
          api.publish.fetchCommentsPage(
            ship,
            notebook,
            noteId,
            loadedComments,
            30
          );
        }
        if (!note.read) {
          api.publish.publishAction({
            read: {
              who: ship.slice(1),
              book: notebook,
              note: noteId,
            },
          });
        }
      }
    } else if (notebook && ship) {
    }
  };

  const panelDisplay = !path ? ["none", "block"] : "block";
  return (
    <Box height="100%" width="100%" px={[0, 3]} pb={[0, 3]}>
      <Box
        display="flex"
        border={[0, 1]}
        borderColor={["washedGray", "washedGray"]}
        borderRadius={1}
        width="100%"
        height="100%"
      >
        <Sidebar
          notebooks={props.notebooks}
          contacts={props.contacts}
          path={path}
          invites={props.invites}
          associations={props.associations}
          selectedGroups={props.selectedGroups}
          api={props.api}
        />
        <Box
          display={panelDisplay}
          width="100%"
          height="100%"
          position="relative"
          px={[3, 4]}
          fontSize={0}
          overflowY="scroll"
          onScroll={onScroll}
        >
          <ErrorBoundary>{props.children}</ErrorBoundary>
        </Box>
      </Box>
    </Box>
  );
}

export default Skeleton;
