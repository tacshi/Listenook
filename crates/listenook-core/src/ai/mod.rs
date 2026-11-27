//! What an AI provider is asked and how its replies are read: briefs, ad searches and
//! translations. Each is a [`Task`] that hands out one [`Ask`] at a time, takes the
//! model's reply to it and says how the recording's [`Job`](crate::Job) changes, so the
//! caller only sends questions, passes answers back and applies the changes.

pub mod ads;
pub mod brief;
pub mod translate;

use serde_json::Value;

use crate::{Change, models::Document};

/// Work the model does on a recording, a question at a time.
pub trait Task {
    /// What its error codes start with (`"translation_"`): a question that could not be
    /// asked fails with this and the reason (`"translation_network_error"`).
    const ERRORS: &'static str;

    /// What to ask the model next, with how far it is to note on the job first; `None`
    /// once every question is answered.
    fn ask(&self) -> Option<(Ask, Option<Change<'static>>)>;

    /// Takes the model's reply to the last [`ask`](Self::ask): what it changes in the
    /// job, or the code of the error that ends the task.
    fn answer(&mut self, reply: &str) -> Result<Option<Change<'static>>, &'static str>;

    /// How it ended, stopped by the error `error` or not, for the job whose transcript is
    /// `document` now (it may have changed while the model thought).
    fn end(self, error: Option<String>, document: &Document) -> Change<'static>;
}

/// A question for the model: the part it plays, what it is asked, and whether it must
/// answer with a JSON object.
#[derive(Debug, Clone, PartialEq)]
pub struct Ask {
    pub system: &'static str,
    pub prompt: String,
    pub json: bool,
}

/// A question whose answer must be a JSON object, asked once more, with a reminder, when
/// a reply is not one.
#[derive(Debug, Clone)]
struct JsonQuestion {
    system: &'static str,
    prompt: String,
    retried: bool,
}

impl JsonQuestion {
    fn new(system: &'static str, prompt: String) -> Self {
        Self { system, prompt, retried: false }
    }

    fn ask(&self) -> Ask {
        let prompt = if self.retried {
            format!(
                "{}\nYour previous response was not valid JSON. Return only one valid JSON object matching the requested shape.",
                self.prompt
            )
        } else {
            self.prompt.clone()
        };
        Ask { system: self.system, prompt, json: true }
    }

    /// The object `decode` reads in `reply`; `Ok(None)` when it holds none and the question
    /// is to be asked again, and `Err` when it held none the second time too.
    fn read(&mut self, reply: &str, decode: fn(&str) -> Option<Value>) -> Result<Option<Value>, ()> {
        match decode(reply) {
            Some(value) => Ok(Some(value)),
            None if self.retried => Err(()),
            None => {
                self.retried = true;
                Ok(None)
            }
        }
    }
}
