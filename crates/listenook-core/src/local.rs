//! Local speech: the models the worker runs, what its results mean, and
//! word alignment's windows and tokens. Running the worker and fetching
//! the models is the app's.

use serde_json::Value;

use crate::models::{Document, Segment, Speaker, Token, now_iso};

/// One file of a model, as its repository has it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModelFile {
    pub path: &'static str,
    pub size: u64,
    pub sha256: &'static str,
}

/// A model the user downloads: a pinned revision of a Hugging Face repository.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Model {
    pub id: &'static str,
    pub name: &'static str,
    pub repository: &'static str,
    pub revision: &'static str,
    pub files: &'static [ModelFile],
}

impl Model {
    /// The download's size in bytes.
    pub fn size(&self) -> u64 {
        self.files.iter().map(|file| file.size).sum()
    }

    /// Where a file is fetched from.
    pub fn url(&self, file: &ModelFile) -> String {
        format!("https://huggingface.co/{}/resolve/{}/{}?download=true", self.repository, self.revision, file.path)
    }
}

const fn f(path: &'static str, size: u64, sha256: &'static str) -> ModelFile {
    ModelFile { path, size, sha256 }
}

pub const MOSS: Model = Model {
    id: "moss-transcribe-diarize-0.9b-coreml-int8",
    name: "MOSS transcription",
    repository: "aufklarer/MOSS-Transcribe-Diarize-0.9B-CoreML-INT8",
    revision: "1cd68cfc84a26f0df95ba0868982d2c185839b62",
    files: &[
        f("config.json", 844, "0bedeebf2874b14940d6182a149c3e106adad1198450eeae8c55a44150c73c42"),
        f(
            "audio_encoder.mlmodelc/metadata.json",
            1841,
            "a7c3fe71682a3aafc0d282bc71824092bde4d69b81f400bc8c16b9c3a556c21a",
        ),
        f(
            "audio_encoder.mlmodelc/model.mil",
            272486,
            "468f9ba7bf4530320144c1acfd4c64985539660f6273dc2f276129a24d2ed614",
        ),
        f(
            "audio_encoder.mlmodelc/coremldata.bin",
            329,
            "d866c92c5fa0f42e78c34e94da40fea00c5daa9b93e0d012795c0eb35d5bc04e",
        ),
        f(
            "audio_encoder.mlmodelc/weights/weight.bin",
            624952768,
            "44ec78b8f543db6ef3facafeb044e443e7c449f3a84f803944c2e8bcd43b4c89",
        ),
        f("decoder/config.json", 1261, "4043dff653976e44fad480de5f92c9b16c519e2560e092d310d4f0010c8d94ff"),
        f(
            "decoder/decoder.mlmodelc/metadata.json",
            39418,
            "e632a67e70f4b674510f80d5a6fdf718ea9ffd33149e816128ebb887d0824b9e",
        ),
        f(
            "decoder/decoder.mlmodelc/model.mil",
            751282,
            "e00406cefded8c35715a2d19e0e0b910b4d3b285a67805c94a362ce5c0d3b8f7",
        ),
        f(
            "decoder/decoder.mlmodelc/coremldata.bin",
            2154,
            "3a746712824b2ea02a0978681098d28008aa4fd4784f554941752d7c21c63342",
        ),
        f(
            "decoder/decoder.mlmodelc/weights/weight.bin",
            633713600,
            "d1d9b4e9879b7971034bbf7ea4d6d8c6cd5078c0acf87928dd079aab6bcce140",
        ),
        f("processor_config.json", 292, "a978c2dd54a65b576c3dae4b654fe9bcbac1184c6db2df0afb2c90fcdc872ae7"),
        f("preprocessor_config.json", 315, "ba2e601484abc80f4cded977f9a4fd4a53175b7d35c2f2511f0cfc3a32ad2499"),
        f("generation_config.json", 107, "e53a4b3ce4f944230cf1ca8fed0c42f4ff0d8c1443eaf98b5315d987334dd9e4"),
        f("tokenizer.json", 11423222, "bcf03774334462d6e34b5005cb11120a62275f146ee2953e68731ecdbce84fbb"),
        f("tokenizer_config.json", 503, "61d04c96104177240688396655ae3f7cf38ce2ea036db867a1d2b6883e27c3d5"),
    ],
};

pub const QWEN3: Model = Model {
    id: "qwen3-asr-0.6b",
    name: "Qwen3 ASR 0.6B",
    repository: "Qwen/Qwen3-ASR-0.6B",
    revision: "5eb144179a02acc5e5ba31e748d22b0cf3e303b0",
    files: &[
        f("config.json", 6193, "76d3ae4601ce939830b2517f4a6cadb86cc51316c3900af6b020b051c21a478c"),
        f("generation_config.json", 142, "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"),
        f("merges.txt", 1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        f("model.safetensors", 1876091704, "79d6cbd4c98c7bbffe9db2edac07f56cd6637d0d5944b27f6c2b8353840323ea"),
        f("preprocessor_config.json", 330, "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
        f("tokenizer_config.json", 12487, "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        f("vocab.json", 2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ],
};

pub const QWEN3_LARGE: Model = Model {
    id: "qwen3-asr-1.7b",
    name: "Qwen3 ASR 1.7B",
    repository: "Qwen/Qwen3-ASR-1.7B",
    revision: "7278e1e70fe206f11671096ffdd38061171dd6e5",
    files: &[
        f("config.json", 6194, "2e74a751548b8ad7d7526d29365ad8144c345d8b412b1152d25dc6698452712f"),
        f("generation_config.json", 142, "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"),
        f("merges.txt", 1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        f(
            "model-00001-of-00002.safetensors",
            4220320824,
            "a4cd1f1a04d90b757dc7f7dd26254e69a013b19e80efe590a83c6a3bde8608d6",
        ),
        f(
            "model-00002-of-00002.safetensors",
            478200688,
            "6e0b9d9e09e2e0238e7ef3cc8a484ab387e91b90f1900bedf88bc92d7929ccfc",
        ),
        f("model.safetensors.index.json", 64821, "f994739fe38e5210b9e3e8ce6c6307315e2ceac3cb630e7b7414d69dce520f60"),
        f("preprocessor_config.json", 330, "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
        f("tokenizer_config.json", 12487, "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        f("vocab.json", 2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ],
};

pub const ALIGNER: Model = Model {
    id: "qwen3-forced-aligner-0.6b",
    name: "Qwen3 word alignment",
    repository: "Qwen/Qwen3-ForcedAligner-0.6B",
    revision: "c7cbfc2048c462b0d63a45797104fc9db3ad62b7",
    files: &[
        f("config.json", 5982, "d616c65d46c4b90bdc651b0a0963ea932732241140f337f9bb6b0335a9c8ef09"),
        f("generation_config.json", 115, "948d089b23bca1d214e768d59c4438365665f52ec6d33678f4062206b3fbbb8c"),
        f("merges.txt", 1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        f("model.safetensors", 1835544544, "47831d0e82f96b20e9034dba01a075ee06436654719f6a68289e49f1b65ce0e7"),
        f("preprocessor_config.json", 330, "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
        f("tokenizer_config.json", 12666, "3ab80063f8511deb9566e6ad438d17b7a6277fcffd52d92854112f19d36bd81c"),
        f("vocab.json", 2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ],
};

/// Every model, in the order they are listed.
pub const MODELS: &[Model] = &[MOSS, QWEN3, QWEN3_LARGE, ALIGNER];

/// The model with this id.
pub fn model(id: &str) -> Option<&'static Model> {
    MODELS.iter().find(|model| model.id == id)
}

// --- Results ------------------------------------------------------------------

fn int(value: &Value, key: &str) -> Option<i64> {
    value.get(key).and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}

/// The worker's MOSS result as a transcript: speakers numbered as they
/// first speak, times kept inside the recording.
pub fn moss_document(result: &Value, duration_ms: i64) -> Document {
    let mut segments = Vec::new();
    let mut speakers: Vec<Speaker> = Vec::new();
    for entry in result.get("segments").and_then(Value::as_array).into_iter().flatten() {
        let text = entry.get("text").and_then(Value::as_str).unwrap_or("").trim();
        let (Some(start), Some(end)) = (int(entry, "start_ms"), int(entry, "end_ms")) else {
            continue;
        };
        let start = start.clamp(0, duration_ms.max(0));
        let end = if duration_ms > 0 { end.clamp(start, duration_ms.max(start)) } else { end };
        if text.is_empty() || end <= start {
            continue;
        }
        let speaker =
            entry.get("speaker").and_then(Value::as_str).map(|s| s.trim().to_uppercase()).filter(|s| !s.is_empty());
        if let Some(id) = &speaker
            && !speakers.iter().any(|known| &known.id == id)
        {
            speakers.push(Speaker { id: id.clone(), name: format!("Speaker {}", speakers.len() + 1) });
        }
        segments.push(Segment {
            id: format!("moss-{}", segments.len()),
            start_ms: start,
            end_ms: end,
            text: text.to_owned(),
            speaker,
            ..Segment::default()
        });
    }
    if segments.is_empty()
        && let Some(text) = result.get("text").and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty())
    {
        segments.push(Segment {
            id: "moss-0".into(),
            end_ms: duration_ms,
            text: text.to_owned(),
            ..Segment::default()
        });
    }
    Document { tokens: Vec::new(), segments, speakers, updated_at: now_iso() }
}

// --- Qwen3 ----------------------------------------------------------------------

/// The languages Qwen3 knows, by the name it calls them and their code.
pub const LANGUAGES: &[(&str, &str)] = &[
    ("Chinese", "zh"),
    ("English", "en"),
    ("Cantonese", "yue"),
    ("Arabic", "ar"),
    ("German", "de"),
    ("French", "fr"),
    ("Spanish", "es"),
    ("Portuguese", "pt"),
    ("Indonesian", "id"),
    ("Italian", "it"),
    ("Korean", "ko"),
    ("Russian", "ru"),
    ("Thai", "th"),
    ("Vietnamese", "vi"),
    ("Japanese", "ja"),
    ("Turkish", "tr"),
    ("Hindi", "hi"),
    ("Malay", "ms"),
    ("Dutch", "nl"),
    ("Swedish", "sv"),
    ("Danish", "da"),
    ("Finnish", "fi"),
    ("Polish", "pl"),
    ("Czech", "cs"),
    ("Filipino", "fil"),
    ("Persian", "fa"),
    ("Greek", "el"),
    ("Romanian", "ro"),
    ("Hungarian", "hu"),
    ("Macedonian", "mk"),
];

/// Qwen3's name for a language hint (`en-US` → `English`).
pub fn language_name(hint: &str) -> Option<&'static str> {
    let code = hint.split(['-', '_']).next().unwrap_or("").to_lowercase();
    LANGUAGES.iter().find(|(_, known)| *known == code).map(|(name, _)| *name)
}

/// Qwen3's name for a language, as this table has it.
pub fn known_language(name: &str) -> Option<&'static str> {
    LANGUAGES.iter().find(|(known, _)| known.eq_ignore_ascii_case(name)).map(|(known, _)| *known)
}

/// The language to split words by when nothing says which: by script.
pub fn guess_language(text: &str) -> &'static str {
    let has = |from: u32, to: u32| text.chars().any(|c| (from..=to).contains(&(c as u32)));
    if has(0x3040, 0x30FF) {
        "Japanese"
    } else if has(0xAC00, 0xD7AF) {
        "Korean"
    } else if has(0x3400, 0x9FFF) {
        "Chinese"
    } else {
        "English"
    }
}

/// The language to split a text's words by, given the job's hints: the
/// one hint, else the hinted language the text's script fits, else what
/// the script says.
pub fn language_for(hints: &[String], text: &str) -> &'static str {
    let hinted: Vec<&'static str> = hints.iter().filter_map(|hint| language_name(hint)).collect();
    let guess = guess_language(text);
    let spaced = |name: &str| !matches!(name, "Chinese" | "Cantonese" | "Japanese" | "Korean");
    match hinted.as_slice() {
        [] => guess,
        [only] => only,
        many if many.contains(&guess) => guess,
        many => many.iter().find(|name| spaced(name) == spaced(guess)).unwrap_or(&many[0]),
    }
}

/// Where to cut a recording into pieces the models take whole: at the
/// quietest tenth of a second in the last stretch of each piece. Returns
/// the end of every piece, in samples.
pub fn cut_points(samples: &[i16], rate: usize, piece_seconds: usize, search_seconds: usize) -> Vec<usize> {
    let (piece, search, frame) = (piece_seconds * rate, search_seconds * rate, (rate / 10).max(1));
    let mut cuts = Vec::new();
    let mut at = 0;
    while samples.len() - at > piece {
        let (from, to) = (at + piece - search, at + piece);
        let energy = |start: usize| -> u64 {
            samples[start..(start + frame).min(to)].iter().map(|s| u64::from(s.unsigned_abs()).pow(2)).sum()
        };
        let quietest = (from..to).step_by(frame).min_by_key(|start| energy(*start)).unwrap_or(to);
        at = (quietest + frame / 2).min(to);
        cuts.push(at);
    }
    cuts.push(samples.len());
    cuts
}

/// A word the aligner timed.
#[derive(Debug, Clone, PartialEq)]
pub struct Word {
    pub text: String,
    pub start_ms: i64,
    pub end_ms: i64,
}

/// A text in sentences: cut after a full stop, a question or exclamation
/// mark, and at a comma once a sentence runs long.
pub fn sentences(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        current.push(c);
        // Closing quotes and brackets stay with their sentence.
        if matches!(c, '.' | '?' | '!' | '…' | '。' | '？' | '！') {
            while let Some(close) = chars.next_if(|next| matches!(next, '"' | '”' | '’' | '」' | '』' | ')' | '）'))
            {
                current.push(close);
            }
        }
        let next_breaks = chars.peek().is_none_or(|next| next.is_whitespace());
        let length = current.chars().map(|c| if is_cjk(c) { 3 } else { 1 }).sum::<usize>();
        let ends = match c {
            '。' | '？' | '！' => true,
            '.' | '?' | '!' | '…' => next_breaks,
            '，' | '、' | '；' => length > 120,
            ',' | ';' => next_breaks && length > 120,
            _ => false,
        };
        if ends {
            let sentence = current.trim();
            if !sentence.is_empty() {
                out.push(sentence.to_owned());
            }
            current.clear();
        }
    }
    let rest = current.trim();
    if !rest.is_empty() {
        match out.last_mut() {
            Some(last) if !rest.chars().any(char::is_alphanumeric) => last.push_str(rest),
            _ => out.push(rest.to_owned()),
        }
    }
    out
}

/// Gives each text the words that are in it, reading words and texts in
/// order. A word found in none of the texts ahead is left out.
pub fn distribute(words: &[Word], texts: &[&str]) -> Vec<Vec<Word>> {
    let mut out = vec![Vec::new(); texts.len()];
    let (mut text, mut at) = (0, 0);
    for word in words {
        let needle = word.text.trim();
        if needle.is_empty() {
            continue;
        }
        let found = (text..texts.len()).find_map(|index| {
            let from = if index == text { at } else { 0 };
            texts[index][from..].find(needle).map(|offset| (index, from + offset + needle.len()))
        });
        if let Some((index, end)) = found {
            (text, at) = (index, end);
            out[index].push(word.clone());
        }
    }
    out
}

/// A sentence's timed words as tokens: inside the sentence, each starting
/// where the one before ends.
pub fn word_tokens(segment: &Segment, words: &[Word]) -> Vec<Token> {
    let mut times: Vec<(i64, i64)> = words
        .iter()
        .map(|word| {
            let start = word.start_ms.clamp(segment.start_ms, segment.end_ms);
            (start, word.end_ms.clamp(start, segment.end_ms))
        })
        .collect();
    for index in 1..times.len() {
        times[index].0 = times[index].0.max(times[index - 1].0);
        times[index].1 = times[index].1.max(times[index].0);
    }
    stabilize(&mut times, segment.end_ms);
    times
        .iter()
        .zip(words)
        .map(|((start, end), word)| Token {
            text: word.text.clone(),
            start_ms: *start,
            end_ms: *end,
            segment_id: Some(segment.id.clone()),
            speaker: segment.speaker.clone(),
            language: segment.language.clone(),
            ..Token::default()
        })
        .collect()
}

/// A piece of a recording as Qwen3 heard it and the aligner timed it, in
/// sentences. `words` are in the recording's time; `end_ms` is the piece's
/// end; sentence ids continue from `first_index`.
pub fn timed_sentences(text: &str, words: &[Word], end_ms: i64, first_index: usize) -> (Vec<Segment>, Vec<Token>) {
    let texts = sentences(text);
    let refs: Vec<&str> = texts.iter().map(String::as_str).collect();
    let per = distribute(words, &refs);
    let mut pieces: Vec<(String, Vec<Word>)> = Vec::new();
    let mut waiting = String::new();
    for (text, words) in texts.iter().zip(per) {
        if words.is_empty() {
            // Nothing timed: it reads with the sentence before, else the next.
            match pieces.last_mut() {
                Some((before, _)) => *before = format!("{before} {text}"),
                None => waiting = format!("{waiting}{text} "),
            }
        } else {
            pieces.push((format!("{waiting}{text}"), words));
            waiting.clear();
        }
    }
    let (mut segments, mut tokens) = (Vec::new(), Vec::new());
    for (index, (text, words)) in pieces.iter().enumerate() {
        let start = words[0].start_ms;
        let next = pieces.get(index + 1).map_or(end_ms, |(_, words)| words[0].start_ms);
        let last = words[words.len() - 1].end_ms;
        // The last word often has no length of its own: let it run to the
        // next sentence, but not across a long silence.
        let end = if last > words[words.len() - 1].start_ms { last } else { next.min(last + 600) };
        let segment = Segment {
            id: format!("qwen3-{}", first_index + segments.len()),
            start_ms: start,
            end_ms: end.max(start + 1).min(next.max(start + 1)),
            text: text.clone(),
            ..Segment::default()
        };
        tokens.extend(word_tokens(&segment, words));
        segments.push(segment);
    }
    (segments, tokens)
}

// --- Word alignment -----------------------------------------------------------

/// The longest sentence the aligner takes, and the longest window.
pub const WINDOW_MAX_MS: i64 = 29_000;
/// What a window adds before its first sentence and after its last.
pub const WINDOW_PADDING_MS: i64 = 250;
const MIN_TOKEN_MS: i64 = 40;

fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF)
}

fn is_word(c: char) -> bool {
    c.is_ascii_alphanumeric()
        || matches!(c as u32, 0x00C0..=0x024F | 0x0300..=0x036F | 0x0400..=0x052F)
        || c == '\''
        || c == '\u{2019}'
}

/// The units of a sentence the aligner times: each CJK character, and each
/// run of letters or of digits.
pub fn units(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut run = String::new();
    let mut run_digits = false;
    for c in text.chars() {
        if is_word(c) {
            if !run.is_empty() && c.is_ascii_digit() != run_digits && (c.is_ascii_digit() || run_digits) {
                out.push(std::mem::take(&mut run));
            }
            run_digits = c.is_ascii_digit();
            run.push(c);
            continue;
        }
        if !run.is_empty() {
            out.push(std::mem::take(&mut run));
        }
        if is_cjk(c) {
            out.push(c.to_string());
        }
    }
    if !run.is_empty() {
        out.push(run);
    }
    out
}

/// A sentence as the aligner gets it.
#[derive(Debug, Clone, PartialEq)]
pub struct AlignSegment {
    pub id: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub units: Vec<String>,
}

/// Sentences aligned in one pass over one stretch of audio.
#[derive(Debug, Clone, PartialEq)]
pub struct Window {
    pub id: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub segments: Vec<AlignSegment>,
}

/// What can be aligned of a transcript.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct AlignmentPlan {
    pub windows: Vec<Window>,
    /// Sentences longer than the aligner takes.
    pub too_long: usize,
}

fn prompt_tokens(first_start: i64, last_end: i64, segments: &[AlignSegment]) -> i64 {
    let padded = last_end - first_start + 2 * WINDOW_PADDING_MS;
    let units: i64 = segments
        .iter()
        .flat_map(|segment| &segment.units)
        .map(|unit| {
            let runes = unit.chars().count() as i64;
            2 + if runes <= 1 { 1 } else { ((runes + 2) / 3).max(1) }
        })
        .sum();
    15 + (padded * 13 + 999) / 1000 + units
}

/// The windows to align a transcript in: sentences that follow each other
/// closely share one, a sentence overlapping another has its own.
pub fn plan(document: &Document) -> AlignmentPlan {
    let mut plan = AlignmentPlan::default();
    let mut eligible: Vec<AlignSegment> = Vec::new();
    for segment in &document.segments {
        let units = units(&segment.text);
        if segment.end_ms - segment.start_ms > WINDOW_MAX_MS {
            plan.too_long += 1;
        } else if !units.is_empty() && segment.end_ms > segment.start_ms {
            eligible.push(AlignSegment {
                id: segment.id.clone(),
                start_ms: segment.start_ms,
                end_ms: segment.end_ms,
                units,
            });
        }
    }
    eligible.sort_by_key(|segment| (segment.start_ms, segment.end_ms));
    let overlaps = |index: usize| {
        let me = &eligible[index];
        eligible.iter().enumerate().any(|(other, s)| other != index && s.start_ms < me.end_ms && me.start_ms < s.end_ms)
    };
    let alone: Vec<bool> = (0..eligible.len()).map(overlaps).collect();
    let mut groups: Vec<Vec<AlignSegment>> = Vec::new();
    for (index, segment) in eligible.iter().enumerate() {
        let joins = !alone[index]
            && index > 0
            && !alone[index - 1]
            && groups.last().is_some_and(|group| {
                let (first, last) = (&group[0], &group[group.len() - 1]);
                let mut with = group.clone();
                with.push(segment.clone());
                segment.start_ms - last.end_ms <= WINDOW_PADDING_MS
                    && segment.end_ms - first.start_ms <= WINDOW_MAX_MS
                    && prompt_tokens(first.start_ms, segment.end_ms, &with) <= 768 - 48
            });
        if joins {
            groups.last_mut().expect("joins needs a group").push(segment.clone());
        } else {
            groups.push(vec![segment.clone()]);
        }
    }
    plan.windows = groups
        .into_iter()
        .enumerate()
        .map(|(index, segments)| Window {
            id: format!("window-{index}"),
            start_ms: (segments[0].start_ms - WINDOW_PADDING_MS).max(0),
            end_ms: segments[segments.len() - 1].end_ms + WINDOW_PADDING_MS,
            segments,
        })
        .collect();
    plan
}

/// The worker's alignment request for some windows.
pub fn stabilize(tokens: &mut [(i64, i64)], segment_end: i64) {
    let count = tokens.len();
    for index in 1..count {
        let (previous, current) = (tokens[index - 1], tokens[index]);
        let mut start = if previous.1 < current.0 {
            (previous.1 + current.0) / 2
        } else if current.0 <= previous.0 || current.0 == current.1 {
            ((previous.0 + previous.1) / 2 + (current.0 + current.1) / 2) / 2
        } else {
            current.0
        };
        let earliest = previous.0 + MIN_TOKEN_MS;
        start = start.max(earliest);
        let latest = segment_end - (count - index) as i64 * MIN_TOKEN_MS;
        if latest >= earliest && start > latest {
            start = latest;
        }
        tokens[index] = (start, current.1.max(start));
    }
    for index in 0..count {
        let end = if index + 1 < count { tokens[index + 1].0 } else { tokens[index].1.max(segment_end) };
        tokens[index].1 = end.max(tokens[index].0);
    }
}

/// The words the worker timed, for the sentences whose answer is usable:
/// one time per unit, in order, inside the sentence. `segments` are the
/// sentences that were asked about.
pub fn spans(text: &str, units: &[(String, i64, i64)]) -> Option<Vec<(String, i64, i64)>> {
    let mut at = 0;
    let mut out: Vec<(String, i64, i64)> = Vec::with_capacity(units.len());
    for (index, (unit, start, end)) in units.iter().enumerate() {
        let needle = unit.trim();
        let found = text[at..].find(needle)? + at;
        let stop = if index + 1 == units.len() { text.len() } else { found + needle.len() };
        out.push((text[at..stop].to_owned(), *start, *end));
        at = stop;
    }
    (!out.is_empty()).then_some(out)
}

/// Timed pieces of a sentence as whole words. A transcription service times
/// pieces smaller than words (`" rem"`, `"inder"`): a piece that neither
/// starts with a space nor follows one belongs to the word before it. A
/// character of a script written without spaces is a word of its own.
pub fn whole_words(pieces: &[(String, i64, i64)]) -> Vec<(String, i64, i64)> {
    let mut words: Vec<(String, i64, i64)> = Vec::new();
    for (text, start, end) in pieces {
        let joins = words.last().is_some_and(|(before, ..)| {
            let glued = !text.starts_with(char::is_whitespace) && !before.ends_with(char::is_whitespace);
            let spaced = |c: Option<char>| c.is_some_and(|c| !is_cjk(c));
            // Punctuation goes with the word before it, whatever the script.
            let punctuation = !text.chars().any(|c| c.is_alphanumeric() || is_cjk(c));
            glued && (punctuation || (spaced(text.chars().next()) && spaced(before.chars().last())))
        });
        match words.last_mut() {
            Some((before, _, last_end)) if joins => {
                before.push_str(text);
                *last_end = (*last_end).max(*end);
            }
            _ => words.push((text.clone(), *start, *end)),
        }
    }
    words
}

/// The word being said at `position_ms`: the last one that has started.
/// A word stays marked until the next begins, so none is passed over in
/// the silence between two, and one with no length of its own is not lost.
/// `words` are in the order they are said.
pub fn word_at(words: &[(String, i64, i64)], position_ms: i64) -> Option<usize> {
    words.partition_point(|(_, start, _)| *start <= position_ms).checked_sub(1)
}

/// A word as it is drawn: what stands before it (spaces, an opening quote)
/// and the word itself, which alone is marked.
pub fn lead_and_word(text: &str) -> (&str, &str) {
    let at = text.find(|c: char| c.is_alphanumeric() || is_cjk(c)).unwrap_or(text.len());
    text.split_at(at)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn the_catalog_is_complete_and_urls_are_pinned() {
        assert_eq!(MODELS.len(), 4);
        assert_eq!(MOSS.size(), 1_271_160_422);
        assert_eq!(
            QWEN3.url(&QWEN3.files[0]),
            "https://huggingface.co/Qwen/Qwen3-ASR-0.6B/resolve/5eb144179a02acc5e5ba31e748d22b0cf3e303b0/config.json?download=true"
        );
        assert!(MODELS.iter().flat_map(|m| m.files).all(|file| file.sha256.len() == 64));
        assert_eq!(model("qwen3-asr-1.7b").map(|m| m.name), Some("Qwen3 ASR 1.7B"));
    }

    #[test]
    fn moss_results_become_segments_with_speakers_in_order() {
        let result = json!({"segments": [
            {"start_ms": 100, "end_ms": 900, "text": " Hi. ", "speaker": "s02"},
            {"start_ms": 900, "end_ms": 99999, "text": "Yes.", "speaker": "S01"},
            {"start_ms": 5, "end_ms": 5, "text": "zero"},
        ]});
        let document = moss_document(&result, 2000);
        assert_eq!(document.segments.len(), 2);
        assert_eq!(document.segments[1].end_ms, 2000);
        assert_eq!(document.speaker_name(Some("S02")), "Speaker 1");
        assert_eq!(document.segments[0].id, "moss-0");
    }

    #[test]
    fn units_split_words_digits_and_cjk() {
        assert_eq!(units("Don’t stop, room42!"), ["Don’t", "stop", "room", "42"]);
        assert_eq!(units("你好 world"), ["你", "好", "world"]);
        assert!(units("…!").is_empty());
    }

    fn document() -> Document {
        let segment = |id: &str, start, end, text: &str| Segment {
            id: id.into(),
            start_ms: start,
            end_ms: end,
            text: text.into(),
            ..Segment::default()
        };
        Document {
            segments: vec![
                segment("a", 0, 1000, "Hello there"),
                segment("b", 1100, 2000, "friend"),
                segment("c", 9000, 50_000, "far too long"),
                segment("d", 60_000, 61_000, "later"),
            ],
            ..Document::default()
        }
    }

    #[test]
    fn close_sentences_share_a_window_and_long_ones_are_left_out() {
        let plan = plan(&document());
        assert_eq!(plan.too_long, 1);
        assert_eq!(plan.windows.len(), 2);
        assert_eq!(plan.windows[0].segments.len(), 2);
        assert_eq!((plan.windows[0].start_ms, plan.windows[0].end_ms), (0, 2250));
        assert_eq!(plan.windows[1].id, "window-1");
    }

    fn word(text: &str, start_ms: i64, end_ms: i64) -> Word {
        Word { text: text.into(), start_ms, end_ms }
    }

    #[test]
    fn text_is_cut_into_sentences() {
        assert_eq!(
            sentences("Hi there. It costs 3.5 dollars! Really?"),
            ["Hi there.", "It costs 3.5 dollars!", "Really?"]
        );
        assert_eq!(sentences("你好。今天天气不错！"), ["你好。", "今天天气不错！"]);
        assert_eq!(sentences("He said \"go.\" Then left"), ["He said \"go.\"", "Then left"]);
    }

    #[test]
    fn words_go_to_the_sentence_they_are_in() {
        let words = [word("Hi", 0, 200), word("there.", 200, 500), word("lost", 500, 600), word("Yes!", 900, 900)];
        let per = distribute(&words, &["Hi there.", "Yes!"]);
        assert_eq!(per[0].len(), 2);
        assert_eq!(per[1], [word("Yes!", 900, 900)]);
    }

    #[test]
    fn a_piece_becomes_timed_sentences() {
        let words =
            [word("Hi", 100, 300), word("there.", 300, 300), word("Yes", 2000, 2400), word("indeed.", 2400, 2900)];
        let (segments, tokens) = timed_sentences("Hi there. Yes indeed.", &words, 5000, 4);
        assert_eq!(segments.len(), 2);
        assert_eq!((segments[0].id.as_str(), segments[0].start_ms, segments[0].end_ms), ("qwen3-4", 100, 900));
        assert_eq!((segments[1].start_ms, segments[1].end_ms), (2000, 2900));
        assert_eq!(tokens.len(), 4);
        assert_eq!(tokens[1].segment_id.as_deref(), Some("qwen3-4"));
        assert!(tokens[1].end_ms > tokens[1].start_ms, "a word with no length gets some");
    }

    #[test]
    fn recordings_are_cut_where_they_are_quiet() {
        let mut samples = vec![1000_i16; 100];
        samples[70..80].fill(0);
        assert_eq!(cut_points(&samples, 10, 8, 4), [70, 100]);
        assert_eq!(cut_points(&samples[..50], 10, 8, 4), [50]);
    }

    #[test]
    fn hints_choose_the_language_words_are_split_by() {
        let hints = |codes: &[&str]| codes.iter().map(|c| (*c).to_owned()).collect::<Vec<_>>();
        assert_eq!(language_for(&hints(&[]), "你好"), "Chinese");
        assert_eq!(language_for(&hints(&["fr"]), "你好"), "French");
        assert_eq!(language_for(&hints(&["de", "ja"]), "こんにちは"), "Japanese");
        assert_eq!(language_for(&hints(&["de", "yue"]), "Guten Tag"), "German");
        assert_eq!(language_for(&hints(&["de", "yue"]), "你好"), "Cantonese");
    }

    #[test]
    fn pieces_are_joined_into_whole_words() {
        let piece = |text: &str, start, end| (text.to_owned(), start, end);
        let pieces = [
            piece("As", 0, 100),
            piece(" like", 100, 300),
            piece(" a", 300, 350),
            piece(" rem", 400, 500),
            piece("inder", 500, 700),
            piece(".", 700, 720),
            piece(" I", 800, 850),
            piece("'ve", 850, 950),
        ];
        let words = whole_words(&pieces);
        let texts: Vec<&str> = words.iter().map(|word| word.0.as_str()).collect();
        assert_eq!(texts, ["As", " like", " a", " reminder.", " I've"]);
        assert_eq!((words[3].1, words[3].2), (400, 720));
        let chinese = whole_words(&[piece("你", 0, 100), piece("好", 100, 200), piece("。", 200, 210)]);
        assert_eq!(chinese.iter().map(|w| w.0.as_str()).collect::<Vec<_>>(), ["你", "好。"]);
    }

    #[test]
    fn the_word_being_said_is_the_last_that_started() {
        let word = |start| (String::new(), start, start + 50);
        let words = [word(100), word(300), word(300), word(900)];
        assert_eq!(word_at(&words, 50), None, "nothing is said yet");
        assert_eq!(word_at(&words, 100), Some(0));
        assert_eq!(word_at(&words, 250), Some(0), "marked through the pause after it");
        assert_eq!(word_at(&words, 300), Some(2));
        assert_eq!(word_at(&words, 5000), Some(3));
        assert_eq!(lead_and_word(" \u{201c}Hello,"), (" \u{201c}", "Hello,"));
        assert_eq!(lead_and_word(" — "), (" — ", ""));
    }

    #[test]
    fn languages_are_named_and_guessed() {
        assert_eq!(language_name("en-US"), Some("English"));
        assert_eq!(language_name("xx"), None);
        assert_eq!(guess_language("こんにちは世界"), "Japanese");
        assert_eq!(guess_language("你好"), "Chinese");
    }

    #[test]
    fn spans_cover_the_whole_sentence() {
        let units = vec![("Hello".to_owned(), 0, 400), ("there".to_owned(), 400, 1000)];
        let spans = spans("Hello, there!", &units).unwrap();
        assert_eq!(spans[0].0, "Hello");
        assert_eq!(spans[1].0, ", there!");
        assert!(super::spans("Other text", &units).is_none());
    }
}
