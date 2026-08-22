use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::{ContentClass, ReadingUnit};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NarrationQueueState {
    Ready,
    AwaitingContent,
    Completed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NarrationQueue {
    pub unit_ids: Vec<String>,
    pub current_index: usize,
    pub state: NarrationQueueState,
}

impl NarrationQueue {
    pub fn from_current(
        units: &[ReadingUnit],
        current_unit_id: &str,
        limit: usize,
    ) -> Option<Self> {
        let start = units
            .iter()
            .position(|unit| unit.unit_id == current_unit_id)?;
        let unit_ids = units[start..]
            .iter()
            // Footnotes stay in the text and on screen, but the voice steps over them: hearing a
            // bibliographic note dropped into the middle of a paragraph breaks the thread of
            // listening, which is the whole point of reading aloud.
            //
            // A chapter title is the opposite: it is what tells a listener where they are, and it
            // is read like the rest. `ReaderViewModel.isNarrable` states the same rule on the Swift
            // side; the two are one decision and must not drift apart.
            .filter(|unit| {
                matches!(
                    unit.content_class,
                    ContentClass::Prose | ContentClass::Heading
                )
            })
            .take(limit.max(1))
            .map(|unit| unit.unit_id.clone())
            .collect::<Vec<_>>();
        (!unit_ids.is_empty()).then_some(Self {
            unit_ids,
            current_index: 0,
            state: NarrationQueueState::Ready,
        })
    }

    pub fn current_unit_id(&self) -> Option<&str> {
        self.unit_ids.get(self.current_index).map(String::as_str)
    }

    pub fn advance(&mut self, processing_complete: bool) {
        if self.current_index + 1 < self.unit_ids.len() {
            self.current_index += 1;
        } else {
            self.state = if processing_complete {
                NarrationQueueState::Completed
            } else {
                NarrationQueueState::AwaitingContent
            };
        }
    }

    pub fn append(&mut self, unit_ids: impl IntoIterator<Item = String>) {
        let mut seen = self.unit_ids.iter().cloned().collect::<BTreeSet<_>>();
        self.unit_ids
            .extend(unit_ids.into_iter().filter(|id| seen.insert(id.clone())));
        if self.state == NarrationQueueState::AwaitingContent
            && self.current_index + 1 < self.unit_ids.len()
        {
            self.current_index += 1;
            self.state = NarrationQueueState::Ready;
        }
    }
}
