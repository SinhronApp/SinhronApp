// ADR-092 — what a phone says with each Commit it sends, so that a member's
// garbage Commit can't freeze a chat.
//
// The server can't read a Commit. Every phone takes the first Commit of its
// epoch that it can apply (they all get a chat's Commits in the same order)
// and drops the rest; the server takes a Commit for epoch E only from a
// device that names the Commit that brought it to E (`parent`) and every
// Commit for E it has seen since and did not take (`refused`). A garbage
// Commit then only waits for the next honest one, instead of making every
// honest Commit a 409. This log keeps those two things per chat; the app
// saves it between runs (a lost log only makes our next Commit wait).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Per chat (group id hex).
#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
pub struct CommitLog(HashMap<String, ChatCommits>);

#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatCommits {
    /// The epoch this record is about (ours when it was written).
    pub epoch: u64,
    /// message_id of the Commit that brought us to `epoch`; empty if unknown
    /// (a Welcome, a card, an older app).
    pub parent: String,
    /// Commits for `epoch` that came since and that we did not take.
    pub refused: Vec<String>,
    /// A Commit came that we did not take: make one of our own, so the
    /// chat's epoch (and its card, ADR-090) is an honest member's again.
    pub heal: bool,
}

impl CommitLog {
    /// A Commit took the chat to `epoch`: one we applied, or ours the server took.
    pub fn moved(&mut self, group: &str, epoch: u64, by: &str) {
        self.0.insert(group.to_string(), ChatCommits { epoch, parent: by.to_string(), ..Default::default() });
    }

    /// A Commit (`id`, made at epoch `at`) came and we did not take it; we are at `mine`.
    pub fn refused(&mut self, group: &str, id: &str, at: u64, mine: u64) {
        // An older Commit in a chat we have no record of: the one that let
        // this device in (held until its Welcome), nothing to heal.
        if at < mine && !self.0.contains_key(group) {
            return;
        }
        let chat = self.0.entry(group.to_string()).or_default();
        if chat.epoch != mine {
            // We moved without a record (joined by a Welcome): parent unknown.
            *chat = ChatCommits { epoch: mine, ..Default::default() };
        }
        if at == mine && !chat.refused.iter().any(|r| r == id) {
            chat.refused.push(id.to_string());
        }
        chat.heal = true;
    }

    /// `(parent, refused)` to send with our Commit made at `epoch`.
    pub fn for_commit(&self, group: &str, epoch: u64) -> (String, Vec<String>) {
        match self.0.get(group) {
            Some(c) if c.epoch == epoch => (c.parent.clone(), c.refused.clone()),
            _ => (String::new(), Vec::new()),
        }
    }

    /// Should we make a Commit of our own in this chat ([`refused`](Self::refused))?
    pub fn needs_heal(&self, group: &str) -> bool {
        self.0.get(group).is_some_and(|c| c.heal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_commit_names_what_it_saw_at_its_own_epoch_only() {
        let mut log = CommitLog::default();
        // A new device's own way in, replayed after its Welcome: ignored.
        log.refused("g", "added-me", 4, 5);
        assert!(!log.needs_heal("g"));
        log.moved("g", 5, "p");
        log.refused("g", "x", 5, 5);
        log.refused("g", "x", 5, 5);
        log.refused("g", "ahead", 6, 5);
        log.refused("g", "old", 4, 5);
        assert_eq!(log.for_commit("g", 5), ("p".to_string(), vec!["x".to_string()]));
        assert_eq!(log.for_commit("g", 6), (String::new(), Vec::new()), "another epoch: nothing known");
        assert!(log.needs_heal("g"));
        log.moved("g", 6, "mine");
        assert_eq!(log.for_commit("g", 6), ("mine".to_string(), Vec::new()));
        assert!(!log.needs_heal("g"));
        // Moved without a record (a Welcome): the parent is unknown.
        log.refused("g", "y", 9, 9);
        assert_eq!(log.for_commit("g", 9), (String::new(), vec!["y".to_string()]));
        let back: CommitLog = serde_json::from_str(&serde_json::to_string(&log).unwrap()).unwrap();
        assert_eq!(back, log);
    }
}
