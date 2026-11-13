// ADR-093 — which of a chat's cards a phone joins by.
//
// Every device in a chat leaves its own card (its MLS GroupInfo) on the
// server. Honest members' cards of one epoch say the same thing — only who
// signed them differs — so a member who leaves garbage (another tree, a
// wrong external key or transcript) is outvoted: the phone takes the
// content its own person left (another device of mine in the chat), or
// else the one most people left. Only the two newest epochs count (a
// member long offline doesn't hold the chat back); a tie goes to the newer
// card. One person can't make two votes with several devices. What is left:
// right after a member's garbage Commit, before any honest phone healed the
// chat (ADR-092), one honest card against hers is a tie — the new phone
// may take hers, its join goes nowhere, and it tries again later.

//
// ADR-100 (audit 2026-11b, CM-01) — a phone now enters only by a card that
// another device of its own person signed (`GroupHandle::join_by_card`),
// so the app hands this choice only its own person's cards: what is left
// of the vote is "the newest of mine first".

use std::collections::HashMap;

/// One card from the server, with the identity key of the person whose
/// device left it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardFromServer {
    pub epoch: u64,
    pub card: Vec<u8>,
    pub identity: [u8; 32],
}

/// What a card says, without who signed it: an Ed25519 GroupInfo ends with
/// the signer's leaf index (4 bytes) and the 64-byte signature with its
/// one-byte length. `None`: not a card of our cipher suite.
pub fn card_content(card: &[u8]) -> Option<&[u8]> {
    const TAIL: usize = 4 + 1 + 64;
    if card.len() <= TAIL || card[card.len() - 65] != 64 {
        return None;
    }
    Some(&card[..card.len() - TAIL])
}

/// The cards to try, best first: one per distinct content of the two newest
/// epochs, ordered by (my person left it, how many people left it, newer).
pub fn cards_to_try(cards: &[CardFromServer], me: &[u8; 32]) -> Vec<Vec<u8>> {
    struct Vote<'a> {
        epoch: u64,
        card: &'a [u8],
        people: Vec<[u8; 32]>,
    }
    let newest = cards.iter().filter(|c| card_content(&c.card).is_some()).map(|c| c.epoch).max().unwrap_or(0);
    let mut votes: HashMap<&[u8], Vote> = HashMap::new();
    for c in cards.iter().filter(|c| c.epoch.saturating_add(1) >= newest) {
        let Some(content) = card_content(&c.card) else { continue };
        let v = votes.entry(content).or_insert(Vote { epoch: c.epoch, card: &c.card, people: Vec::new() });
        if !v.people.contains(&c.identity) {
            v.people.push(c.identity);
        }
        // My own device's card of this content is the one to use.
        if c.identity == *me {
            v.card = &c.card;
        }
    }
    let mut order: Vec<Vote> = votes.into_values().collect();
    order.sort_by_key(|v| (!v.people.contains(me), std::cmp::Reverse(v.people.len()), std::cmp::Reverse(v.epoch), v.card.to_vec()));
    order.into_iter().map(|v| v.card.to_vec()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(content: &[u8], signer: u8) -> Vec<u8> {
        let mut c = content.to_vec();
        c.extend_from_slice(&[0, 0, 0, signer]);
        c.push(64);
        c.extend_from_slice(&[signer; 64]);
        c
    }

    fn from(content: &[u8], who: u8) -> CardFromServer {
        at(5, content, who)
    }

    fn at(epoch: u64, content: &[u8], who: u8) -> CardFromServer {
        CardFromServer { epoch, card: card(content, who), identity: [who; 32] }
    }

    #[test]
    fn most_people_win_over_a_member_who_came_first() {
        let cards = [from(b"garbage", 9), from(b"honest", 1), from(b"honest", 2)];
        let got = cards_to_try(&cards, &[7; 32]);
        assert_eq!(card_content(&got[0]), Some(&b"honest"[..]));
        assert_eq!(card_content(&got[1]), Some(&b"garbage"[..]));
    }

    #[test]
    fn my_own_persons_card_wins_even_alone() {
        let cards = [from(b"garbage", 9), from(b"garbage", 8), from(b"mine", 7)];
        let got = cards_to_try(&cards, &[7; 32]);
        assert_eq!(got[0], card(b"mine", 7));
    }

    #[test]
    fn one_person_with_many_devices_is_one_vote() {
        let mut cards = vec![from(b"honest", 1)];
        for _ in 0..5 {
            cards.insert(0, from(b"garbage", 9));
        }
        cards.push(from(b"honest", 2));
        let got = cards_to_try(&cards, &[7; 32]);
        assert_eq!(card_content(&got[0]), Some(&b"honest"[..]));
    }

    #[test]
    fn a_tie_goes_to_the_newer_card_and_odd_bytes_are_skipped() {
        let cards = [
            CardFromServer { epoch: 6, card: b"short".to_vec(), identity: [3; 32] },
            at(4, b"older", 1),
            at(5, b"newer", 2),
        ];
        let got = cards_to_try(&cards, &[7; 32]);
        assert_eq!(got.len(), 2);
        assert_eq!(card_content(&got[0]), Some(&b"newer"[..]));
    }

    /// Two people long offline left the same old card: it doesn't outvote
    /// the chat's current one (it would only get 409 forever).
    #[test]
    fn cards_older_than_the_two_newest_epochs_dont_count() {
        let cards = [at(9, b"now", 1), at(3, b"old", 2), at(3, b"old", 4)];
        let got = cards_to_try(&cards, &[7; 32]);
        assert_eq!(got.len(), 1);
        assert_eq!(card_content(&got[0]), Some(&b"now"[..]));
    }

    /// Right after a member's garbage Commit (epoch 6, only her card) two
    /// honest people's cards of epoch 5 still win: the join gets 409 and
    /// waits for the chat to heal, instead of entering her branch.
    #[test]
    fn honest_cards_of_the_epoch_before_beat_one_members_newer_card() {
        let cards = [at(6, b"fork", 9), at(5, b"honest", 1), at(5, b"honest", 2)];
        let got = cards_to_try(&cards, &[7; 32]);
        assert_eq!(card_content(&got[0]), Some(&b"honest"[..]));
    }

    /// Fuzz finding 12/cli-mls-F3 — the epoch is the server's word: the
    /// largest one must not overflow (a panic in debug, a wrap in release).
    #[test]
    fn the_largest_epoch_does_not_overflow() {
        let cards = [at(u64::MAX, b"a", 1), at(u64::MAX - 1, b"b", 2), at(3, b"c", 3)];
        assert_eq!(cards_to_try(&cards, &[9; 32]).len(), 2, "the two newest epochs");
    }
}
