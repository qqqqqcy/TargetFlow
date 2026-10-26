import Foundation

/// The one-step timeline prompt for Codex: the shared one-step prompt plus rules written from
/// GPT Luna's graded mistakes, and an output shape that has the model note each frame before it
/// writes the cards.
enum CodexTimelinePrompt {
  static let system = "You generate precise Target Flow timeline cards in valid JSON only."

  static let additionalRules = #"""
    - Write one detailedSummary line per minute by default. Merge minutes into one line only when the frames are the same screen with nothing new on it, and then say so. A minute in which a message arrived, a draft changed, a reply appeared or the page changed gets its own line.
    - Each line must let someone who never saw the screen know what was on it. Name the specific thing: the author and subject of the post, the title of the video, the sender and subject of the email, the person or channel in the chat, the file, function or command, the search query, the option or figure being discussed. "viewed the X home feed", "browsed YouTube recommendations", "read the reply" and "other posts" are too vague; write "viewed X home feed: Paul Graham's post about a building facade" or "read Codex's reply listing three fixes for the scroll bug".
    - For every chat, email or assistant prompt, say which of three states the text is in. A message that sits in the thread, above a reply or with a delivered or working status, was sent: write sent "...". Text in the input box is a draft: write typed an unsent draft "...". Text from someone else was received: write who it came from. Greyed placeholder text in an empty input box (for example "Explain this codebase") is not something the user typed. Do not use the word "entered". A message that was already in the thread in an earlier frame was not sent again in this minute.
    - A coding assistant running inside a terminal is named by its own banner or prompt (Codex, Claude Code). Ghostty, Terminal and iTerm are only the window it runs in: write "Codex in Ghostty", never "Ghostty's reply". Commands, queries and edits shown in the assistant's output were run by the assistant, not by the user.
    - Describe each minute from its own frame. Do not move something from the frame before or after into this minute, and do not let one line borrow the topic of the line above it.
    - Name the concrete event with the most supported foreground time. An editor, terminal, coding assistant or design tool does not by itself prove work on a goal. Choose the secondary category label from the event's actual subject and purpose, not the app name; keep short unrelated visits in the details.
    - Consecutive off-topic minutes are ONE distraction entry covering the whole stretch, with a summary that says what was looked at. Never list one entry per minute.
    - Before answering, check every time you wrote: all of them carry the same AM or PM as the frame labels, and no line ends after the window ends.
    - The frame labels are the only clock. Every startTime, endTime and detail-line time comes from the labels under INPUTS, in order: the first image is the first label. Ignore the menu-bar clock and any other time visible inside a screenshot; never copy it into a time field.
    """#

  static let outputBlock = #"""
    OUTPUT:
    Return ONLY a raw JSON object. No code fences, no markdown, no commentary. Fill "frames" first, then "cards".
    - "frames": one entry per screenshot, in order, written before you decide anything about cards. "note" is one or two factual sentences: the frontmost app, the page, file or thread that is open, what the user is doing there, and any text the user typed with whether it was sent or is still a draft. Follow the reading rules above.
    - "cards": the timeline cards, built from the previous cards and your frame notes. Every frame note must be reflected in a detailedSummary line.

    {
      "frames": [
        {"time": "1:12 AM", "app": "", "note": ""}
      ],
      "cards": [
        {
          "startTime": "1:12 AM",
          "endTime": "1:30 AM",
          "category": "",
          "subcategory": "",
          "title": "",
          "summary": "",
          "detailedSummary": "",
          "distractions": [
            {"startTime": "1:15 AM", "endTime": "1:18 AM", "title": "", "summary": ""}
          ],
          "appSites": {"primary": "", "secondary": ""}
        }
      ]
    }
    """#
}
