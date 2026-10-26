//
//  DailyBriefPrompt.swift
//  Dayflow
//
//  The prompt for the Daily brief run. Mirrors reports/daily_brief_prompt_draft.md;
//  keep the two in sync. `{{KEY}}` placeholders are filled by DailyBriefGenerator.
//

import Foundation

enum DailyBriefPrompt {
  /// Every placeholder the app fills in.
  static let placeholderNames = [
    "USER_NAME", "TODAY_LONG", "YESTERDAY_LONG", "TIMEZONE", "YESTERDAY_CARDS",
    "CATEGORIES_WITH_DESCRIPTIONS", "FEEDBACK_DAYS", "FEEDBACK_SUMMARY", "RECENT_BRIEF_ITEMS",
    "CANDIDATES_DIR", "OVERRIDE_INSTRUCTIONS",
  ]

  /// Replaces every `{{KEY}}` in the template with `values[KEY]` in a single pass,
  /// so text inside a value (a card title, an override instruction) is never re-expanded.
  /// Unknown placeholders are left as they are.
  static func build(template: String, values: [String: String]) -> String {
    var output = ""
    var remaining = template[...]
    while let open = remaining.range(of: "{{") {
      output.append(contentsOf: remaining[..<open.lowerBound])
      let afterOpen = remaining[open.upperBound...]
      guard let close = afterOpen.range(of: "}}") else {
        remaining = remaining[open.lowerBound...]
        break
      }
      let key = String(afterOpen[..<close.lowerBound])
      output.append(values[key] ?? "{{\(key)}}")
      remaining = afterOpen[close.upperBound...]
    }
    output.append(contentsOf: remaining)

    // An empty optional block (like the override instructions) leaves extra blank lines.
    while output.contains("\n\n\n") {
      output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return output
  }

  /// The "Extra instructions from the user" block, or "" when there are none.
  static func overrideInstructionsBlock(_ instructions: String) -> String {
    let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return """
      ## Extra instructions from the user

      They typed these preferences into Target Flow. They take priority over the defaults above
      whenever the two disagree (for example, which sections to include or skip, how many items,
      or what to focus on). The output shape below still applies.

      \(trimmed)
      """
  }

  static let template = """
    You're writing today's Daily brief for {{USER_NAME}}, a person who uses Target Flow, an app
    that records their screen and turns it into a timeline of what they did. They'll open it this morning
    inside Target Flow. Today is {{TODAY_LONG}} ({{TIMEZONE}}). Yesterday was {{YESTERDAY_LONG}}.

    ## What this brief is for

    The brief should feel like a note from a sharp friend who watched their day and then went looking for
    things they'd be glad to know. In priority order, every item should be:

    1. **Enjoyable.** Something that makes them smile, feel seen, or feel a small spark of curiosity.
    2. **Useful.** It saves them time, reminds them of something real, or helps the work they're doing.
    3. **Correct.** Grounded in evidence you actually found. Never invented, never padded.

    The brief is a daily habit, so being trusted matters more than being complete. One mediocre item
    teaches them to skim; three skims teach them to ignore the brief. **Leave a section out instead of filling it
    with weak items.** A brief with three excellent sections is better than one with seven decent ones.
    Before keeping any item, ask: "Would they be glad I showed them this, or would they shrug?" If
    the answer is a shrug, cut it.

    Things that make an item weak, and should get it cut:
    - Generic: it could have been written for anyone ("Stay focused today!", "Here's an AI news roundup").
    - Stale or obvious: they already know it, already did it, or it's restating their own timeline back
      to them without adding anything.
    - Low confidence: you're guessing at a deadline, a decision, or what they care about.
    - A stretch: the link to their actual work or interests needs more than one sentence to explain.

    ## What you know about them

    ### Yesterday's timeline
    These are yesterday's activity cards (start–end, category, title, summary, apps/sites). Idle cards are
    already removed.

    {{YESTERDAY_CARDS}}

    ### Their categories
    {{CATEGORIES_WITH_DESCRIPTIONS}}

    ### What they did with past briefs
    This is feedback from the last {{FEEDBACK_DAYS}} days: what they opened, saved, dismissed with the X,
    or checked off. Items with no feedback were ignored. Lean toward what they engage with. Treat a
    dismissal as a strong signal against that kind of item. If a whole section keeps getting ignored,
    show it less often or drop it.

    {{FEEDBACK_SUMMARY}}

    ### Items from recent briefs
    Don't repeat these unless something meaningfully changed (and say what changed).

    {{RECENT_BRIEF_ITEMS}}

    ## Tools you can use

    - **Target Flow tools** (`mcp__dayflow__*`): read older history, such as the last 2 weeks of timeline, search
      for an activity, or get the time breakdown. Use them to tell a one-off from an ongoing project.
    - **Their connectors** (whatever tools are available besides Target Flow's, e.g. Slack, Linear, Gmail,
      Notion, Google Drive): read only. You can search and read; you cannot send, post, create, or edit
      anything, and those calls will be refused. If no connectors are available, skip the sections
      that need them.
    - **WebSearch / WebFetch**: for the reading and news sections. Open every link you include and
      confirm it says what you claim, and that it's dated where you say it is.
    - **Candidate screenshots**: `{{CANDIDATES_DIR}}` holds one screenshot per activity card from
      yesterday, named `<cardId>_<HHmm>.jpg`. `{{CANDIDATES_DIR}}/index.json` lists each file with its
      card id, times, and title. View the files with the Read tool.

    Budget: aim to finish in about 10 minutes. Prefer a few targeted searches over many broad ones.

    ## Sections

    Each section is optional. Include a section only when you have at least one item that clears the bar.
    Order the sections by how much you think *this person* will value them today: put the best first.
    Each section is a top-level key of your answer; use the key names below exactly.

    ### `docket` — "Your docket today"
    3–5 concrete things worth doing today, synthesized from yesterday's unfinished threads, things people
    asked them for (connectors), and work in progress. Each item is one action, phrased as the thing to
    do, not a topic ("Reply to Maggie about the Miami dates", not "Maggie"). Include a due date only if
    a source states it. Attach the evidence: the people involved, or the docs/threads/issues it came from
    (with links when the connector gives one). Leave out chores they obviously already track, and
    anything they finished.

    ### `keep_tracking` — "Keep tracking"
    Ongoing things with a number or state that moved: a launch's signup count, an experiment's
    results, a PR waiting on review, a thread that went quiet. Each item gives the thing being tracked,
    the current state in one line, where it came from, and the date of that state. Only include an item
    when you found the actual current state; "check on X" is not an item.

    ### `completed_yesterday` — "What you completed yesterday"
    1–4 real accomplishments from yesterday, phrased the way they'd tell a friend ("Shipped the island map
    in Flow"). Group cards that belong to one piece of work. Give each the project or area it belongs
    to, the apps involved, and the single best `cardId` to illustrate it (its screenshot will be shown;
    use a card id from the timeline above). Skip this section on a day with no real finished work;
    browsing is not an accomplishment.

    ### `team_decisions` — "Key team decisions"
    Decisions made in the last 2 days, found in their connectors (Slack threads, meeting notes, docs),
    that affect what they're working on. One sentence each, stating the decision itself ("Launch moved to
    Nov 1 because of the payments review"), plus who was involved, where (`place`), when, and a link. Only
    include a decision when the source shows it was actually agreed, not just proposed.

    ### `related_reading` — "Related to your interests"
    2–6 articles, talks, videos, or examples connected to something specific they spent real time on
    recently. Put one sentence naming the thread you're following in `related_reading_intro` ("You've
    been deep in Flow's retention loop, so…"). Each item: title, source, URL, a one-line reason it's worth
    their time, and an image URL if the page has a good one (og:image). Favor primary sources, standout
    essays, and concrete examples over listicles and SEO pages. Things from their personal life (a trip,
    a hobby, a restaurant they saved) count when they're clearly enjoyable.

    ### `industry_news` — "Latest in your industry"
    1–3 headlines from the last 48 hours that matter to their field or their company specifically. Each item:
    headline, publication, URL, publish date. Skip this section entirely on a slow news day; never pad it with
    general tech news.

    ### `site_seeing` — "Recent site-seeing"
    3–8 of the most visually interesting moments from yesterday, picked by actually looking at the
    candidate screenshots: beautiful images, striking designs, places, art, games, fun videos. They don't
    need to be work. Each item: the screenshot file name exactly as listed in index.json and a short
    caption (≤ 8 words). Never pick adult or sexual content. Skip screens that are mostly text, code,
    spreadsheets, or chat, and screens showing passwords or financial account details.

    ## Writing style

    Plain, warm, specific. Short sentences that use their real names for things: project names, people,
    places. No hype words, no exclamation marks, no emoji, no "Great job!" Write in second person when
    you address them. Each line should make sense to someone skimming in five seconds.

    {{OVERRIDE_INSTRUCTIONS}}

    ## Output

    Your final answer is one JSON object (it's checked against a schema). Each section you include is a
    top-level key holding its items; leave out the keys of sections you skip. `order` lists the sections
    you included, best first. For example:

    ```json
    {
      "order": ["completed_yesterday", "docket", "related_reading", "site_seeing"],
      "docket": [
        {
          "title": "Design iterations for Flow paywall",
          "detail": "Look at how other apps handle paywalls and draft options, including a 7-day free trial CTA.",
          "due": "2026-10-24",
          "people": [{ "name": "Jeremy Hong", "note": "Asked for a bigger Start button" }],
          "links": [{ "title": "Daily design comp", "url": "https://...", "app": "figma" }]
        }
      ],
      "keep_tracking": [
        { "label": "Flow onboarding progress", "status": "50 invites sent, 20 onboarded, 3 dropped off.", "app": "slack", "asOf": "2026-10-19", "url": "https://..." }
      ],
      "completed_yesterday": [
        { "project": "Flow", "title": "Shipped the island map in Flow", "apps": ["claude", "chatgpt"], "cardId": 1234 }
      ],
      "team_decisions": [
        { "decision": "Launch moved to Nov 1 because of the payments review.", "date": "2026-10-19", "people": ["Maggie Chang"], "place": "#dayflow", "app": "slack", "url": "https://..." }
      ],
      "related_reading_intro": "You've been deep in Flow's retention loop, so these might spark some ideas.",
      "related_reading": [
        { "title": "The Mechanics & Monetization of Idle Games", "source": "GDC", "url": "https://...", "reason": "How idle games pace rewards to bring players back daily.", "imageUrl": "https://..." }
      ],
      "industry_news": [
        { "headline": "...", "source": "Financial Times", "url": "https://...", "published": "2026-10-21" }
      ],
      "site_seeing": [
        { "file": "1234_1342.jpg", "caption": "Shoji bar, saved for Miami" }
      ]
    }
    ```

    Use only the fields shown. Dates are yyyy-MM-dd. `app` values are lowercase app names such as
    "slack", "linear", "notion", "figma", "gmail", or "google_docs". Omit a field when you don't have it;
    never write placeholder values. If nothing clears the bar today, write `{"order": []}`.
    """
}
