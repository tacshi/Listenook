//! Transcripts and briefs as TXT, Markdown, SRT and WebVTT.

use std::sync::LazyLock;

use regex::Regex;

use crate::{
    format::{clock, cue_time, safe_file_name},
    models::{AiBrief, AiInsightType, ContentMode, Document, ExportFormat, ExportOptions, Job},
};

static NUMBERED_SPEAKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^Speaker (\d+)$").unwrap());

impl ExportFormat {
    /// The file extension.
    pub fn extension(self) -> &'static str {
        match self {
            ExportFormat::Txt => "txt",
            ExportFormat::Markdown => "md",
            ExportFormat::Srt => "srt",
            ExportFormat::WebVtt => "vtt",
        }
    }

    /// The name shown in the export dialog.
    pub fn label(self) -> &'static str {
        match self {
            ExportFormat::Txt => "Plain text",
            ExportFormat::Markdown => "Markdown",
            ExportFormat::Srt => "SRT",
            ExportFormat::WebVtt => "WebVTT",
        }
    }
}

fn speaker_name(document: &Document, id: Option<&str>, options: &ExportOptions) -> String {
    if !options.show_speakers {
        return String::new();
    }
    let name = document.speaker_name(id);
    if options.locale_code == "zh"
        && let Some(found) = NUMBERED_SPEAKER.captures(&name)
    {
        return format!("说话人 {}", &found[1]);
    }
    name
}

/// The job's transcript in the chosen format; empty without a transcript.
pub fn export_transcript(job: &Job, options: &ExportOptions) -> String {
    let Some(document) = &job.document else {
        return String::new();
    };
    match options.format {
        ExportFormat::Txt => txt(document, options),
        ExportFormat::Markdown => markdown(job, document, options),
        ExportFormat::Srt => cues(document, options, false),
        ExportFormat::WebVtt => cues(document, options, true),
    }
}

/// The file name an export is saved under.
pub fn export_file_name(job: &Job, format: ExportFormat) -> String {
    format!("{}.{}", safe_file_name(&job.title(), "transcript"), format.extension())
}

fn txt(document: &Document, options: &ExportOptions) -> String {
    document
        .segments
        .iter()
        .map(|segment| {
            let mut prefix = Vec::new();
            if options.show_timestamps {
                prefix.push(format!("[{}]", clock(segment.start_ms)));
            }
            let speaker = speaker_name(document, segment.speaker.as_deref(), options);
            if !speaker.is_empty() {
                prefix.push(speaker);
            }
            let content = segment.content(options.content_mode);
            if prefix.is_empty() { content } else { format!("{}: {content}", prefix.join(" ")) }
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn markdown(job: &Job, document: &Document, options: &ExportOptions) -> String {
    let zh = options.locale_code == "zh";
    let mut out = format!("# {}\n\n", job.title());
    out.push_str(if zh { "- 由聆页导出\n" } else { "- Exported by Listenook\n" });
    let duration = clock(job.duration_ms());
    out.push_str(&if zh { format!("- 时长：{duration}\n\n") } else { format!("- Duration: {duration}\n\n") });
    for segment in &document.segments {
        let mut labels = Vec::new();
        let speaker = speaker_name(document, segment.speaker.as_deref(), options);
        if !speaker.is_empty() {
            labels.push(speaker);
        }
        if options.show_timestamps {
            labels.push(clock(segment.start_ms));
        }
        if !labels.is_empty() {
            out.push_str(&format!("**{}**\n\n", labels.join(" · ")));
        }
        if options.content_mode == ContentMode::Bilingual && segment.has_translation() {
            let translated = segment.translated_text.as_deref().unwrap_or("").trim();
            out.push_str(&format!("{translated}\n\n*{}*\n\n", segment.text));
        } else {
            out.push_str(&format!("{}\n\n", segment.content(options.content_mode)));
        }
    }
    out.trim_end().to_owned()
}

fn cues(document: &Document, options: &ExportOptions, vtt: bool) -> String {
    let separator = if vtt { '.' } else { ',' };
    let mut out = String::new();
    if vtt {
        out.push_str("WEBVTT\n\n");
    }
    for (index, segment) in document.segments.iter().enumerate() {
        if !vtt {
            out.push_str(&format!("{}\n", index + 1));
        }
        out.push_str(&format!(
            "{} --> {}\n",
            cue_time(segment.start_ms, separator),
            cue_time(segment.end_ms, separator)
        ));
        let speaker = speaker_name(document, segment.speaker.as_deref(), options);
        let content = segment.content(options.content_mode);
        if speaker.is_empty() {
            out.push_str(&content);
        } else {
            out.push_str(&format!("<v {speaker}>{content}"));
        }
        out.push_str("\n\n");
    }
    out.trim_end().to_owned()
}

/// A brief as Markdown, each item with the time of its first evidence.
pub fn export_brief(job: &Job, brief: &AiBrief) -> String {
    let time_of = |ids: &[String]| -> String {
        job.document
            .as_ref()
            .and_then(|d| d.segments.iter().find(|s| ids.contains(&s.id)))
            .map(|s| format!(" ({})", clock(s.start_ms)))
            .unwrap_or_default()
    };
    let mut out = format!("# {}\n", job.title());
    if !brief.overview.trim().is_empty() {
        out.push_str(&format!("\n## Overview\n\n{}\n", brief.overview.trim()));
    }
    if !brief.chapters.is_empty() {
        out.push_str("\n## Chapters\n");
        for chapter in &brief.chapters {
            out.push_str(&format!(
                "\n### {}{}\n\n{}\n",
                chapter.title,
                time_of(&chapter.evidence_segment_ids),
                chapter.summary
            ));
        }
    }
    let groups = [
        ("Key ideas", vec![AiInsightType::KeyIdea, AiInsightType::NotableMoment]),
        ("Decisions", vec![AiInsightType::Decision]),
        ("Action items", vec![AiInsightType::ActionItem]),
        ("Open questions", vec![AiInsightType::OpenQuestion]),
    ];
    for (title, kinds) in groups {
        let items: Vec<_> = brief.insights.iter().filter(|i| kinds.contains(&i.kind)).collect();
        if items.is_empty() {
            continue;
        }
        out.push_str(&format!("\n## {title}\n\n"));
        for item in items {
            let mut line = format!("- {}", item.text);
            if let Some(owner) = &item.owner {
                line.push_str(&format!(" — {owner}"));
            }
            if let Some(deadline) = &item.deadline {
                line.push_str(&format!(", {deadline}"));
            }
            out.push_str(&format!("{line}{}\n", time_of(&item.evidence_segment_ids)));
        }
    }
    if !brief.language_notes.is_empty() {
        out.push_str("\n## Language notes\n\n");
        for note in &brief.language_notes {
            out.push_str(&format!("- **{}** — {} (“{}”)\n", note.term, note.explanation, note.source_excerpt));
        }
    }
    out.trim_end().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{MediaMetadata, Segment, Speaker};

    fn job() -> Job {
        Job {
            source_path: "/m/Team sync.mp3".into(),
            metadata: Some(MediaMetadata { duration_ms: 65_000, ..Default::default() }),
            document: Some(Document {
                segments: vec![
                    Segment {
                        id: "segment-1".into(),
                        start_ms: 0,
                        end_ms: 1500,
                        text: "Hello.".into(),
                        speaker: Some("1".into()),
                        translated_text: Some("你好。".into()),
                        ..Default::default()
                    },
                    Segment {
                        id: "segment-2".into(),
                        start_ms: 2000,
                        end_ms: 3250,
                        text: "Bye.".into(),
                        ..Default::default()
                    },
                ],
                speakers: vec![Speaker { id: "1".into(), name: "Speaker 1".into() }],
                ..Default::default()
            }),
            ..Job::default()
        }
    }

    #[test]
    fn txt_prefixes_time_and_speaker() {
        let options = ExportOptions { show_timestamps: true, ..Default::default() };
        assert_eq!(export_transcript(&job(), &options), "[00:00] Speaker 1: Hello.\n\n[00:02]: Bye.");
    }

    #[test]
    fn srt_and_vtt_cues() {
        let mut options =
            ExportOptions { format: ExportFormat::Srt, content_mode: ContentMode::Bilingual, ..Default::default() };
        assert_eq!(
            export_transcript(&job(), &options),
            "1\n00:00:00,000 --> 00:00:01,500\n<v Speaker 1>你好。\nHello.\n\n2\n00:00:02,000 --> 00:00:03,250\nBye."
        );
        options.format = ExportFormat::WebVtt;
        options.show_speakers = false;
        options.content_mode = ContentMode::Original;
        assert!(export_transcript(&job(), &options).starts_with("WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nHello."));
    }

    #[test]
    fn markdown_has_a_header_and_chinese_speakers() {
        let options = ExportOptions { format: ExportFormat::Markdown, locale_code: "zh".into(), ..Default::default() };
        let text = export_transcript(&job(), &options);
        assert!(text.starts_with("# Team sync\n\n- 由聆页导出\n- 时长：01:05\n\n**说话人 1**\n\nHello."));
        assert_eq!(export_file_name(&job(), ExportFormat::Markdown), "Team sync.md");
    }
}
