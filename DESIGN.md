# Listenook design

Listenook is a quiet reading-and-listening tool. The transcript is the
product; everything else gets out of its way.

## Structure

The app opens on Home, which gathers what to do next. Its first row is
Today (a ring filling toward the daily goal, today's listening and practice
minutes, and the streak of days the goal was met) beside Continue (what was
played last, recordings and podcast episodes together, each resuming where
it stopped); on a narrow page Today is a row above Continue. Activity
follows once two days have time: bars of the last 7 or 30 days, listening
under practice with a line at the goal, beside a calendar of the last 20
weeks (12 on a narrow page), the hovered day said under each. Then
Processing (while something transcribes or waits), Recently added, and New
episodes from the shows followed. A section with nothing to show is not
drawn; with nothing at all, Home is one empty state.

Learning time is the seconds something plays (a recording, an episode, a
video) and the seconds a practice mode is open and in use (an input in the
last two minutes), counted once however many report it. Each device keeps
its own per-day log in `activity.json`; Sync merges the logs, so every
device shows the time of all of them. The goal is set from Today's menu or
Settings › General. A card's
context menu (a secondary click, or a finger held on it) takes it off
Continue or Recently added, with Undo in the toast; nothing is deleted, and
an item taken off Continue returns once it is opened or played again.

A recording lives in one place. The Library lists every recording whatever
its state (not transcribed, transcribing, ready), newest first or in the
order its Sort menu keeps (last played, title, shortest first); In progress
(in the sidebar while something waits or transcribes), groups and tags are
filters in the sidebar, not other lists. A row names two of its tags (one on
a narrow page) and counts the rest. Opening a recording covers the list
with the reader, and Back returns; one with no transcript yet says so in a
toast instead, offering Transcribe or Retry. Podcasts is for finding and
following shows; a show's page filters its episodes by title and notes, and
an episode's notes open under its row. An episode sent to the Library is a
recording like any other.

Sync with another device on the same network sits at the foot of the
sidebar, above Settings, and says when a sync runs or how the last one
ended: one dialog chooses the device and follows the sync. Two devices pair
once, with a code the other one shows, and paired devices then sync without
asking. Both Libraries end as their
union, and so do the podcasts followed (an unfollow made after a follow
wins) and the place left in each episode (the one saved last wins); whether
this device can be found is set in that dialog, where it matters.

The reader has one transport and one side panel showing one thing at a time:
Practice, the AI Brief, or the video. Practice is not a side column: it docks
as a composer card across the bottom third of the reader, under the
full-width transcript, centered and at most 720pt wide on a desktop, the
whole width on a phone or tablet, where it sits on the software keyboard and
the transport steps aside while that is up. Its top row switches between
Type answer and Mimic, in that order (understand, then say it), and holds the
mode's own controls; Practice opens in the mode used last, Type answer at
first. Type answer has no
options: until it is answered, the sentence plays again
1.5 s after each time it ends (typing holds that off until 1.5 s after the
last key), the transport's play button plays it from its start, a wrong
check plays it at once, and a right one moves to the next sentence after
1.5 s. Replay (its glyph with ⌘R beside it on a computer) plays it again,
and ⌘R does while typing. A word a letter off (or a swap, or an
apostrophe) is marked amber, close rather than wrong; words run together or
apart (`theright`, `the right`) match. Missed twice, the sentence plays at
0.75× until it is answered or left, and a Hint shows the first mistake's first
letters, then the word. A sentence typed wrong at its first check is kept to
review, with the recording (so it lasts and syncs), until it is typed right at
the first try; the card's top row counts this time round (right at the first
try out of those checked) and a Missed chip goes through only those. At the end
of the recording, or of those to review, the box shows what the time round came
to, the words to listen for, and Review missed or Start over, and the top row
keeps only the mode switch; leaving Type answer says the count in a toast.
Mimic's card has the previous sentence, play or pause, and the next beside its
reps, so a pass is steered without leaving it.

The transcript follows the sentence playing until the user scrolls it by hand
(a wheel, a trackpad, a finger, the scroll bar). Then it stays put, and once
the sentence playing is out of view a Jump to playing button at its foot
brings it back; picking a sentence, stepping, seeking or pressing play follows
again too. While searching, the matched words are washed amber.

What the computer plays can be recorded into the Library, on a Mac (macOS
14.2 and later) and on Windows: a video in a browser, a call, an app with no
file to add. The + in the Library's and Home's top bars opens Add to Library,
a menu of where to add from, each source with its glyph, a line saying what
it is and its shortcut: Files… (⌘O) and Record what’s playing (⇧⌘R); on a
phone, where files are the only source, + chooses files at once. Record
what’s playing (that menu, the empty states, File › ⇧⌘R, the tray menu)
starts recording at once,
in one dialog: the recording light breathing, the time, and the last 12
seconds of sound as bars growing from the middle. On a Mac it is a tap of
every app but Listenook; macOS asks the first time, and when it is refused
the dialog says where to allow it and starts once the app is back in front.
What Listenook plays itself pauses as recording starts. The dialog can be
closed: recording goes on, and a Recording row with its light and time sits
in the sidebar above Sync, and the light and the time stand beside the + in
the top bars; either opens it again, as does the + menu's Show the
recording (in place of Record what’s playing while one waits). Pause holds it (Space too); Stop
lays the whole recording out to trim: its name, a waveform with a line where
the preview plays (a press or a drag on it moves the line; Space plays and
pauses, skipping what is cut), a range slider for its start and end, and Cut
out silent gaps, on by default: the silence before the first sound and after
the last, and any stretch of two seconds or more without sound, leaving a
0.3-second pause. What is cut is drawn faint on a band washed with the ink (`foreground` at 7%), and the
dialog says how much it keeps and how much silence it cuts. Save to Library
keeps it as an M4A (AAC), Transcribe beside it starting the transcription.
A recording not saved when the app quits is offered again at the next start
(a toast, and the sidebar row); Discard… deletes it, after asking.

A setting is made where it is used: how to transcribe in the Library's
options, what a transcript shows in the reader's menu, accounts and defaults
in Settings.

## Targets

Desktop first (macOS, then Windows and Linux): pointer and keyboard, 32pt
controls, a persistent sidebar, anchored menus, centered dialogs. The layout
holds from 760pt wide; the reader's side panel is 400pt.

## Visual language

Neutral paper and ink with one violet accent (`primary`). Flat surfaces
separated by hairlines; shadows only on what floats (menus, dialogs, toasts).

| Token | Role |
| --- | --- |
| `background`, `foreground` | The page and its text |
| `card`, `popover`, `sidebar` | Their surfaces |
| `muted`, `muted-foreground` | Supporting regions and text |
| `primary` (+ `-hover`, `-active`) | The default commit, the play button, selection emphasis |
| `hover` | The wash under the pointer, weaker than a selection |
| `accent` | Selected rows and open triggers |
| `control-border` | The edge of fields, selects and checkboxes (3:1 against the page) |
| `destructive` | Destructive actions and errors |
| `success`, `warning` | A finished job, a job that needs attention; `warning` at 28% (`tokens::found`) washes a search match in the transcript |
| `listen`, `practice` | Learning time in charts: emerald for listening, hot orange for practice. The one place Home goes bright; never used for actions |
| `recording` | The recording light and the live meter while recording: the red of a tape machine's light; never used for actions |
| `highlight`, `highlight-foreground` | The sentence being played |
| `scrim` | The layer behind a dialog |

Colors live in `theme.json` and are read through `nsh_base::theme()` and
`src/ui/tokens.rs`. No color literal appears in page or component code.

- **Radius:** `radius` 8 for controls and popups, `radius-sm` 6 for small
  parts (badges, checkboxes, inset rows), `radius-lg` 12 for cards and
  dialogs. Full circles only for status dots, switch thumbs and artwork-less
  avatars.
- **Type:** the platform UI font. `text-lg` page titles, `text-lg`
  transcript text, `text-2xl` practice sentences and answers, `text-sm` interface text,
  `text-xs` metadata. Two weights:
  regular and medium/semibold. Times use tabular figures.
- **Spacing:** Tailwind's 4pt scale. 24pt page inset shared by every region
  of a page (`ui::PAGE_INSET`); 4 / 8 / 12 / 16 / 24 for parts of a control,
  related controls, one group, groups in a section, sections.
- **Density:** medium. On a computer controls are 32pt (28pt small) and
  fields and selects share those heights; on a phone or tablet 40pt (32pt
  small). Rows 32–60pt.
- **Icons:** Lucide outlines, 1.75 stroke, 16pt in controls (14pt small;
  18–20pt under a finger).
- **Focus:** a field's own edge turns `ring` on any focus. Controls draw no
  ring of their own: on an iPad with a keyboard one stayed on the reader's
  play button after every tap.

## The `ui` layer

`src/ui/` is the only place `nsh_base` controls are styled. Pages compose:

| Component | Variants and states |
| --- | --- |
| `button`, `icon_text_button`, `icon_button`, `icon_button_as`, `toggle_icon_button` | Primary, Default, Outline, Ghost, Picture (over a video) × Sm, Md; hover, pressed (scale 0.97 / 0.94), disabled |
| `shortcut_button` | A small ghost button with its glyph and its shortcut's `key_cap` (Replay ⌘R) |
| `floating_button` | Over content (Jump to playing): the popup surface and its shadow, rising in |
| `toggle_button` | An icon button that is on or off (a side panel, repeat): tinted and announced as selected while on |
| `menu_trigger` | The square button a menu or popover opens from; pressed while it is open |
| `text_field`, `bound_field`, `text_area`, `search_field`, `field`, `hint`, `error_hint` | One look: `control-border` edge on `card`, focus edge, placeholder; a search field shows a clear button while it has text; `error_hint` in `destructive` |
| `switch`, `checkbox`, `checkbox_row`, `select`, `segmented`, `slider`, `progress_bar` | Checked, disabled, indeterminate; `checkbox_row` is a card's whole row, washing under the pointer |
| `menu`, `menu_with`, `context_menu`, `menu_action`, `menu_choice`, `menu_danger`, `menu_toggle`, `menu_divider` | One popup surface (`tokens::popup_surface`) |
| `menu_source` | A menu row for where to add from: glyph, name, a muted line under it, the shortcut at its end |
| `modal`, `modal_actions`, `confirm_destructive` | Centered dialog; the system's alert for confirmations |
| `toast`, `toast_host` | Info, Success, Error |
| `page_header`, `card`, `section`, `separator`, `list_row`, `badge`, `empty_state`, `spinner`, `key_cap` | |
| `pressable_card`, `moment_chip` | A card pressed as a whole (Home); a moment's play glyph and time (the Brief's evidence) |
| `recording_dot`, `recording_button` | The recording light (breathing while live, grey while paused); a small outline button with the light and the time |
| `live_wave`, `waveform`, `range_slider` | The last seconds recorded as bars from the middle; a whole recording with what is cut faint on a washed band and the preview's line; a track with a handle at each end |
| `chart::goal_ring`, `chart::day_bars`, `chart::heatmap`, `chart::heat_key`, `chart::swatch` | `nsh_base::plot` marks in `listen` (listening, calendar shades) and `practice`; the goal line in `foreground` at 45% |

A look a page needs becomes a variant here first.

## Motion tokens

`tokens::motion`: `INSTANT` 120ms (hover washes, colors), `FAST` 180ms
(presses, control state), `BASE` 240ms (a selection moving, a popup leaving). Pressed buttons scale to 0.97, icon buttons to 0.94.
With reduced motion, presses do not scale, entrances land at once
(`Motion::play` does this itself) and lists jump instead of scrolling.

## Motion inventory

### Shell

| Change | Motion | Reduced |
| --- | --- | --- |
| Hover / press on a sidebar row | Wash in `INSTANT`; deeper wash on press | Instant |
| Current place or filter changes | The row's fill cross-fades, `INSTANT` | Instant |
| Page changes | The new page fades in (sibling sections cross-fade) | Instant |
| Podcast starts playing | The mini player rises in from the bottom edge | Appears |
| Play ↔ pause | Glyph swap on the button; the button presses to 0.94 | No scale |
| Sleep timer set or off (mini player and reader transport) | The moon-zzz button's tint cross-fades, `INSTANT`; the time left appears beside it and counts down in place, only while something plays | Instant |
| The sleep timer runs out | Every player pauses; the button turns back to the plain glyph | Same |
| A toast arrives / leaves | Rises 16pt and fades in, `BASE`; fades and shrinks out | Instant |
| A sync runs or ends | The status beside Sync in the sidebar changes in place | Same |
| Something starts or stops waiting to transcribe | The In progress row appears under Library, or leaves (not while it is the filter shown), without motion | Same |

### Home

| Change | Motion | Reduced |
| --- | --- | --- |
| Hover / press on a card or row | Wash `INSTANT`; deeper on press | Instant |
| Work runs | The progress bar's fill glides between values, `BASE` | Static bar |
| Search opens | The search bar appears under the header without motion | Same |
| A section gains or loses everything it shows | It appears or leaves without motion | Same |
| Home first shows | The goal ring sweeps round to today's time; the bars grow from the baseline (plot appear, 2 × `BASE`) | Appear |
| Minutes are added or the goal changes | The ring sweeps and the bars grow to their new values, the goal line moving with the scale (plot update, `BASE`) | Jumps |
| Week ↔ Month | The segmented indicator slides; the new bars grow in | Appear |
| Hover or arrow keys over the bars | The other bars dim, `INSTANT`; the caption under them says the day in place of the key | Instant |
| Hover over the calendar | The caption under it says the day in place of the key | Same |
| The goal is met | The ring closes and its line turns to "Goal met" in `success` | Same |
| Nothing to show | The empty state fades in | Appears |

### Library

| Change | Motion | Reduced |
| --- | --- | --- |
| A job is added | Its card rises in | Appears |
| A job's status changes | The status dot's color cross-fades, `BASE`; the glyph swaps | Instant |
| Work runs | The progress bar's fill glides between values, `BASE`; indeterminate while the length is unknown | Static bar |
| Row or Sort menu opens | Grows from 0.95 and fades, 200ms; leaves in 150ms; its button stays pressed while it is open | Instant |
| Sort changes | The rows take their new order at once | Same |
| A row with no transcript is pressed | Wash and press as any row; a toast says why, with Transcribe or Retry | Instant |
| Empty Library | The empty state fades in | Appears |

### Reader

| Change | Motion | Reduced |
| --- | --- | --- |
| The played sentence changes | The highlight fill cross-fades between rows, `BASE`; while the list follows playback it scrolls it to a third of the way down | Jumps |
| The transcript is scrolled by hand while it plays | It stops following; once the sentence playing is out of view, Jump to playing rises in at its foot (`FadeInUp`), its arrow pointing up or down to it. Pressed, the list scrolls back and follows again | Appears; jumps |
| Hover on a sentence | Wash `INSTANT`; its commands fade in, `INSTANT` (they are also on its context menu and on E / R) | Instant |
| Sentence menu opens (secondary click) | As a row menu | Instant |
| Words selected in a sentence | The platform's selection; a Bold toggle fades in among the sentence's own commands, `INSTANT`, tinted while the selected words are bold. Highlighted words turn bold at once (also from the sentence menu, and ⌘B while words are selected; with none, ⌘B shows or hides the sidebar) | Instant |
| Full screen | The transport turns light on the picture; it fades out while playing and back on pointer movement, `BASE` | Instant |
| A finger on the picture (phones and tablets; the video player too) | Held still: it plays at 3× under a "3×" pill at the top until the finger lifts. Dragged sideways: it scrubs (a full width is two minutes, or the whole video), the time and the offset in a card at the center. Dragged up or down: the left half sets the screen's brightness, the right half the volume, a level bar in the card. Double-tapped: that half skips 10 s back or ahead, and taps right after keep skipping. A tap shows or hides the transport (full screen) or plays and pauses (beside the transcript). The card leaves 600 ms after the finger lifts | Same |
| Repeat on / off | The repeat button's tint cross-fades, `FAST` | Instant |
| A repeat stretches or shrinks | A `primary` rail runs down the left of the repeated sentences and changes by a row at once; the last one carries the handle (one less, the count, one more) | Same |
| The handle is dragged | The rail's end follows the finger sentence by sentence; the handle stays where it was picked up, its fill deepened, and moves to the new last sentence when the finger lifts | Same |
| The handle is held near the list's top or bottom edge | The list scrolls on, faster the closer the finger is to the edge, and the repeat keeps following the finger; playback stops moving the list meanwhile | Same |
| A side panel opens or changes | Its toolbar toggle's fill cross-fades, `FAST`; the panel takes its width at once | Instant |
| Position | No motion: the slider follows playback 10 times a second and the thumb 1:1 while dragged | — |
| Search opens | The search bar drops in from the header; the matched words in each sentence are washed amber as the query changes | Appears |
| Practice opens or changes mode | The composer card rises in at the bottom of the reader, `FadeInUp` | Appears |
| Dictation checked | The typed words turn into green and red marks in place. Right: the marks rise in. Wrong: they shake once, and the first word typed wrong comes selected | Appears |
| Mimic between passes | The reps badge turns to the accent while it is the user's turn; the card's play button swaps glyph with the transport's | Same |
| Type answer reaches the end | The summary rises in over the box; the top row's sentence, Replay, Check and Next leave at once | Appears |
| AI Brief generating | Progress bar, indeterminate for a single request | Static |
| Evidence chip pressed | Wash; the transcript scrolls to the sentence | Jumps |

### Sync

| Change | Motion | Reduced |
| --- | --- | --- |
| The Sync dialog or a sync request opens | As every dialog: fades in whole, the card rising a little | Appears |
| A device is found | Its row rises in | Appears |
| Looking for devices | A spinner beside the hint while none is listed | Static glyph |
| Visible on / off | The switch as in Settings; the name field appears under it without motion | Instant |
| Waiting for the other device | Progress bar, indeterminate | Static bar |
| Copying | The bar's fill glides between values, `BASE`; the counts change in place | Static bar |
| The sync ends | The dialog's content swaps to the result, which rises in; a toast on the device that answered | Appears |

### Podcast

| Change | Motion | Reduced |
| --- | --- | --- |
| Featured shows arrive | Cards rise in | Appear |
| Hover / press on a card or row | Wash `INSTANT`; deeper on press | Instant |
| Searching | A spinner while the first results load; results replace it without motion (they change per keystroke) | Static glyph |
| A Browse chip is chosen | The shown cards dim to half, `FAST`, until the shelf's shows replace them; a spinner while the first ones load | Instant dim, static glyph |
| An episode plays | Its row takes the highlight fill, `INSTANT`, and keeps it under the pointer; play ↔ pause glyph swap | Instant |
| Episodes filtered | The rows narrow to the matches at once (per keystroke) | Same |
| An episode's notes open / close | Its notes toggle's tint cross-fades, `INSTANT`; the notes appear under the row in place of the line's preview, without motion | Instant |

### Recording

| Change | Motion | Reduced |
| --- | --- | --- |
| The + menu opens | As a row menu: grows from 0.95 and fades, 200ms; leaves in 150ms; the + stays pressed while it is open | Instant |
| The dialog opens, or comes back from the sidebar or a top bar | As every dialog: fades in whole, the card rising (`FadeInUp`) | Appears |
| Getting ready | A spinner beside the line | Static glyph |
| Recording | The light breathes (`Breathe`, 1.8 s, in and out); the bars move left as sound comes in, ten times a second; the time counts up in place, tabular | The light rests; the bars still move (they are the data) |
| Pause ↔ Resume | The light stops breathing and turns grey; the bars turn grey; the button's glyph and label swap | Same, without breathing |
| Nothing heard yet → sound | The hint under the bars changes in place | Same |
| Refused, or nothing heard | The explanation fades in (`FadeIn`) | Appears |
| Stop | The dialog's content swaps to the trim view, the title with it | Same |
| Trim handles dragged | The washed band and the kept bars follow the handles 1:1; the totals change in place | Same |
| Cut out silent gaps on / off | The switch as in Settings; the gaps' bars turn faint or back to `primary` at once, and the summary changes | Same |
| A press or drag on the waveform | The preview's line jumps there and follows the pointer | Same |
| The preview plays | Its line moves with playback, 20 times a second, and jumps over what is cut | Same |
| Saving | The button says Saving… and is disabled | Same |
| Saved | The dialog leaves as every dialog; a toast with Show | Instant |
| A recording runs or waits | The Recording row appears in the sidebar above Sync, its light breathing, its time counting; while it runs, the light and time appear beside the + | The light rests |

### Settings

| Change | Motion | Reduced |
| --- | --- | --- |
| Tab changes | The segmented indicator slides; the panel swaps without motion (its content is already there) | Jumps |
| A switch flips | The thumb slides and the track's color cross-fades, `FAST` | Instant |
| Theme changes | Colors follow the theme natively | Same |
