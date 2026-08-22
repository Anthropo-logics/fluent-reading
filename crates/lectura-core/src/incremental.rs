use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IncrementalPageState {
    Pending,
    Processing,
    Completed,
    Failed,
    Skipped,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IncrementalPage {
    pub page_index: u32,
    pub state: IncrementalPageState,
    pub error_code: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IncrementalSession {
    pub document_id: String,
    pub visible_page_index: u32,
    pub cancelled: bool,
    pub pages: Vec<IncrementalPage>,
}

impl IncrementalSession {
    pub fn new(document_id: String, page_count: u32, visible_page_index: u32) -> Option<Self> {
        if document_id.is_empty() || page_count == 0 || visible_page_index >= page_count {
            return None;
        }
        let mut pages = Vec::new();
        pages.try_reserve_exact(page_count as usize).ok()?;
        pages.extend((0..page_count).map(|page_index| IncrementalPage {
            page_index,
            state: IncrementalPageState::Pending,
            error_code: None,
        }));
        Some(Self {
            document_id,
            visible_page_index,
            cancelled: false,
            pages,
        })
    }

    pub fn is_valid(&self) -> bool {
        !self.document_id.is_empty()
            && self.document_id.len() <= 256
            && !self.pages.is_empty()
            && (self.visible_page_index as usize) < self.pages.len()
            && self.pages.iter().enumerate().all(|(index, page)| {
                page.page_index as usize == index
                    && (page.state == IncrementalPageState::Failed) == page.error_code.is_some()
                    && page.error_code.as_deref().is_none_or(is_safe_error_code)
            })
            && self
                .pages
                .iter()
                .filter(|page| page.state == IncrementalPageState::Processing)
                .count()
                <= 1
            && (!self.cancelled
                || self
                    .pages
                    .iter()
                    .all(|page| page.state != IncrementalPageState::Processing))
    }

    pub fn reprioritize(&mut self, visible_page_index: u32) -> bool {
        if visible_page_index >= self.pages.len() as u32 {
            return false;
        }
        self.visible_page_index = visible_page_index;
        true
    }

    pub fn next_page(&mut self) -> Option<u32> {
        if self.cancelled
            || self
                .pages
                .iter()
                .any(|page| page.state == IncrementalPageState::Processing)
        {
            return None;
        }
        // Nearest pending page to what the reader is looking at. Proximity decides the order, not
        // whether a page is worth doing at all: a window that also capped the work left the
        // continuous scroll running out of text a few pages ahead of the reader, with the rest of
        // the book never extracted.
        let visible = self.visible_page_index;
        let page = self
            .pages
            .iter_mut()
            .filter(|page| page.state == IncrementalPageState::Pending)
            .min_by_key(|page| page.page_index.abs_diff(visible))?;
        page.state = IncrementalPageState::Processing;
        Some(page.page_index)
    }

    pub fn complete(&mut self, page_index: u32) -> bool {
        self.transition(
            page_index,
            IncrementalPageState::Processing,
            IncrementalPageState::Completed,
            None,
        )
    }

    pub fn fail(&mut self, page_index: u32, error_code: String) -> bool {
        if !is_safe_error_code(&error_code) {
            return false;
        }
        self.transition(
            page_index,
            IncrementalPageState::Processing,
            IncrementalPageState::Failed,
            Some(error_code),
        )
    }

    pub fn retry(&mut self, page_index: u32) -> bool {
        self.transition(
            page_index,
            IncrementalPageState::Failed,
            IncrementalPageState::Pending,
            None,
        )
    }

    /// Puts a page back in the queue so it is read again from scratch.
    ///
    /// [`retry`](Self::retry) only rescues a page that *failed*. A page that came back perfectly
    /// well but was read along the wrong axis — a sheet printed sideways that the reader has just
    /// turned (Story 6.15) — is `Completed`, and `retry` leaves it exactly where it is: the page
    /// turned on screen and went on being narrated the old way. A page the reader skipped can be
    /// asked for again for the same reason.
    ///
    /// A page that is being read right now is left alone: the pass already running would complete
    /// it straight back out of the queue.
    pub fn reread(&mut self, page_index: u32) -> bool {
        let Some(page) = self.pages.get_mut(page_index as usize) else {
            return false;
        };
        if !matches!(
            page.state,
            IncrementalPageState::Completed
                | IncrementalPageState::Failed
                | IncrementalPageState::Skipped
        ) {
            return false;
        }
        page.state = IncrementalPageState::Pending;
        page.error_code = None;
        true
    }

    pub fn skip(&mut self, page_index: u32) -> bool {
        let Some(page) = self.pages.get_mut(page_index as usize) else {
            return false;
        };
        if !matches!(
            page.state,
            IncrementalPageState::Failed | IncrementalPageState::Pending
        ) {
            return false;
        }
        page.state = IncrementalPageState::Skipped;
        page.error_code = None;
        true
    }

    pub fn cancel(&mut self) {
        self.cancelled = true;
        for page in &mut self.pages {
            if page.state == IncrementalPageState::Processing {
                page.state = IncrementalPageState::Pending;
            }
        }
    }

    pub fn resume(&mut self) -> bool {
        if !self.cancelled {
            return false;
        }
        self.cancelled = false;
        true
    }

    pub fn completed_count(&self) -> u32 {
        self.pages
            .iter()
            .filter(|page| page.state == IncrementalPageState::Completed)
            .count() as u32
    }

    fn transition(
        &mut self,
        page_index: u32,
        from: IncrementalPageState,
        to: IncrementalPageState,
        error_code: Option<String>,
    ) -> bool {
        let Some(page) = self.pages.get_mut(page_index as usize) else {
            return false;
        };
        if page.state != from {
            return false;
        }
        page.state = to;
        page.error_code = error_code;
        true
    }
}

fn is_safe_error_code(code: &str) -> bool {
    !code.is_empty()
        && code.len() <= 128
        && code
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
}
