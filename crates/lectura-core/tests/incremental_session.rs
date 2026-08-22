use lectura_core::{IncrementalPageState, IncrementalSession};

#[test]
fn prioritizes_visible_page_and_preserves_checkpoints_on_cancel() {
    let mut session = IncrementalSession::new("doc_0000000000000001".into(), 5, 3).unwrap();
    assert_eq!(session.next_page(), Some(3));
    assert!(session.complete(3));
    assert_eq!(session.next_page(), Some(2));
    session.cancel();
    assert_eq!(session.completed_count(), 1);
    assert_eq!(session.pages[3].state, IncrementalPageState::Completed);
    assert_eq!(session.pages[2].state, IncrementalPageState::Pending);
    assert_eq!(session.next_page(), None);
}

#[test]
fn resumes_pending_work_after_explicit_retry_of_a_cancelled_session() {
    let mut session = IncrementalSession::new("doc_0000000000000001".into(), 5, 2).unwrap();
    assert_eq!(session.next_page(), Some(2));
    session.cancel();

    assert!(session.resume());
    assert!(!session.cancelled);
    assert_eq!(session.next_page(), Some(2));
    assert!(!session.resume());
}

#[test]
fn isolates_failure_and_supports_retry_or_skip() {
    let mut session = IncrementalSession::new("doc_0000000000000001".into(), 3, 1).unwrap();
    assert_eq!(session.next_page(), Some(1));
    assert!(session.fail(1, "LF_PDF_PAGE_UNREADABLE".into()));
    assert_eq!(session.next_page(), Some(0));
    assert!(session.complete(0));
    assert!(session.retry(1));
    assert_eq!(session.next_page(), Some(1));
    assert!(session.fail(1, "LF_PDF_PAGE_UNREADABLE".into()));
    assert!(session.skip(1));
    assert_eq!(session.pages[0].state, IncrementalPageState::Completed);
    assert_eq!(session.pages[1].state, IncrementalPageState::Skipped);
}

#[test]
fn navigation_reprioritizes_only_pending_work() {
    let mut session = IncrementalSession::new("doc_0000000000000001".into(), 8, 0).unwrap();
    assert_eq!(session.next_page(), Some(0));
    assert!(session.complete(0));
    assert!(session.reprioritize(6));
    assert_eq!(session.next_page(), Some(6));
}

/// A long book is extracted in full, nearest to the reader first. An earlier version stopped at a
/// window of four pages around the visible one, which is what made the continuous immersion scroll
/// run out of text a few pages ahead of the reader while most of the book stayed unread.
#[test]
fn thousand_page_session_extracts_the_whole_book_nearest_to_the_reader_first() {
    let mut session = IncrementalSession::new("doc_long".into(), 1_000, 0).unwrap();

    // Order of service, not amount of work: the visible page first, then its neighbours.
    let mut served = Vec::new();
    for _ in 0..4 {
        let page = session.next_page().unwrap();
        served.push(page);
        assert!(session.complete(page));
    }
    assert_eq!(served, vec![0, 1, 2, 3]);

    // Jumping to the end of the book serves that neighbourhood next, not page 4.
    assert!(session.reprioritize(999));
    let page = session.next_page().unwrap();
    assert_eq!(page, 999);
    assert!(session.complete(page));
    assert_eq!(session.next_page(), Some(998));
    assert!(session.complete(998));

    // And nothing is left behind: the run ends with every page accounted for.
    while let Some(page) = session.next_page() {
        assert!(session.complete(page));
    }
    assert_eq!(session.completed_count(), 1_000);
    assert!(
        session
            .pages
            .iter()
            .all(|page| page.state == IncrementalPageState::Completed)
    );
}

#[test]
fn rejects_fabricated_or_inconsistent_snapshots() {
    let mut session = IncrementalSession::new("doc_0000000000000001".into(), 2, 0).unwrap();
    assert!(session.is_valid());
    session.pages[1].page_index = 0;
    assert!(!session.is_valid());

    let mut session = IncrementalSession::new("doc_0000000000000001".into(), 2, 0).unwrap();
    session.pages[0].error_code = Some("LF_FAKE".into());
    assert!(!session.is_valid());
}

#[test]
fn rejects_cancelled_work_and_untrusted_error_text() {
    let mut session = IncrementalSession::new("doc_opaque".into(), 1, 0).unwrap();
    assert_eq!(session.next_page(), Some(0));
    session.cancelled = true;
    assert!(!session.is_valid());

    session.cancelled = false;
    session.pages[0].state = IncrementalPageState::Failed;
    session.pages[0].error_code = Some("document contents leaked".into());
    assert!(!session.is_valid());
}

/// A page that came back perfectly well can be asked for again.
///
/// This is what a reader turning a sideways page needs (Story 6.15): the page is `Completed`, and
/// `retry` — which only rescues a page that *failed* — leaves it exactly where it is, so the page
/// turned on screen and went on being narrated along the old axis. Asking to re-read it puts it
/// back in the queue; a page already being read is left alone, because the pass in flight would
/// complete it straight back out.
#[test]
fn a_page_that_succeeded_can_be_asked_for_again_but_one_in_flight_cannot() {
    let mut session = IncrementalSession::new("doc_0000000000000001".into(), 3, 0).unwrap();
    assert_eq!(session.next_page(), Some(0));
    assert!(session.complete(0));

    // `retry` is the wrong tool for a page that did not fail, and says so.
    assert!(!session.retry(0));
    assert_eq!(session.pages[0].state, IncrementalPageState::Completed);

    assert!(session.reread(0));
    assert_eq!(session.pages[0].state, IncrementalPageState::Pending);
    assert_eq!(session.next_page(), Some(0));
    // Now in flight: asking again would only race the pass that is already running.
    assert!(!session.reread(0));

    // A page the reader skipped can be asked for again too; a failed one keeps working as before,
    // and its error code does not survive into the fresh attempt.
    assert!(session.complete(0));
    assert_eq!(session.next_page(), Some(1));
    assert!(session.fail(1, "LF_PDF_PAGE_UNREADABLE".into()));
    assert!(session.skip(1));
    assert!(session.reread(1));
    assert_eq!(session.pages[1].state, IncrementalPageState::Pending);
    assert_eq!(session.pages[1].error_code, None);

    assert!(!session.reread(9));
}
