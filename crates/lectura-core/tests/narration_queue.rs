use lectura_core::{
    ContentClass, NarrationQueue, NarrationQueueState, ProcessingRoute, ReadingUnit,
    ReadingUnitKind, UnitOrderKey,
};

fn unit(id: &str, content_class: ContentClass, index: u32) -> ReadingUnit {
    ReadingUnit {
        unit_id: id.into(),
        kind: ReadingUnitKind::Paragraph,
        content_class,
        narration_disposition: None,
        processing_route: ProcessingRoute::DirectText,
        order_key: UnitOrderKey {
            primary_page_index: 0,
            local_index: index,
        },
        text: id.into(),
        spoken_text: id.into(),
        source_regions: vec![],
        source_block_ids: vec![],
        parent_unit_id: None,
        confidence: 1.0,
        decision_trace: vec![],
    }
}

#[test]
fn narration_starts_at_current_skips_unsupported_and_resumes_without_duplicates() {
    let units = vec![
        unit("before", ContentClass::Prose, 0),
        unit("current", ContentClass::Prose, 1),
        unit("formula", ContentClass::Formula, 2),
        unit("next", ContentClass::Prose, 3),
    ];
    let mut queue = NarrationQueue::from_current(&units, "current", 3).unwrap();
    assert_eq!(queue.unit_ids, ["current", "next"]);
    queue.advance(false);
    assert_eq!(queue.current_unit_id(), Some("next"));
    queue.advance(false);
    assert_eq!(queue.state, NarrationQueueState::AwaitingContent);
    queue.append(["next".into(), "later".into()]);
    assert_eq!(queue.current_unit_id(), Some("later"));
    assert_eq!(queue.unit_ids, ["current", "next", "later"]);
}
