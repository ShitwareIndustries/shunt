# Social Media Strategy

Platform-by-platform strategy for Shitware Industries' social presence. Covers pre-launch, launch, and post-launch phases.

## Platform Priorities

| Platform | Priority | Status | Why |
|----------|----------|--------|-----|
| Twitter/X | Primary | Active (@ShitwareIndustr) | Developer community is active. Short-form technical content works. Build-in-public is the strategy. |
| Hacker News | Primary | No account needed (per-launch) | Show HN is the launch catalyst. Technical depth only. |
| r/LocalLLaMA | Secondary | Blocked on account with history | Core audience for self-hosted LLM infra. Sustained referral traffic. |
| LinkedIn | Skip | CEO directive | Wrong audience at this stage. |
| Reddit (general) | Skip | — | Noise. LocalLLaMA only. |

## Twitter/X Strategy

### Pre-Launch (Build in Public)

**Content pillars:**

| Pillar | Frequency | Example |
|--------|-----------|---------|
| Technical progress | 2-3x/week | "Got KV-cache routing working across 3 llama.cpp instances. 40% fewer tokens recomputed." |
| Architecture decisions | 1x/week | "Why shunt is built in Zig, not Go: single binary, zero deps, C-level perf." |
| Open source philosophy | 1x/week | "Every line of shunt is AGPL v3. No open core. No bait-and-switch." |
| Community engagement | Daily | Reply to LLM infra discussions. Share others' work. |

**Voice guidelines:**

- Technical first, personality second
- No "thrilled to announce" language
- Short, punchy observations over long threads
- Each tweet in a thread must add value, not just pad the count
- Hashtags: minimal (#llm #selfhosted only when relevant)

**What NOT to post before launch:**

- No screenshots of broken/unfinished UI
- No "coming soon" teasers with no substance
- No metrics without context
- No engagement bait polls

### Launch Day

1. **Lead tweet**: One-sentence product statement + GitHub link
2. **Problem tweet**: "Most LLM load balancers ignore your KV cache. That's wasteful."
3. **Solution tweet**: "shunt routes requests to the instance with the best cache hit. Drop-in OpenAI API replacement."
4. **Demo tweet**: CLI output showing cache hit routing in action
5. **Quick start tweet**: 3 commands to get running
6. **CTA tweet**: "Star us on GitHub. Try it. Tell us what breaks."

**Timing**: Post 5 minutes after Show HN goes live. Pin lead tweet.

### Post-Launch

| Content | Frequency |
|---------|-----------|
| Usage tips | 2x/week |
| Benchmark snippets | 1x/week |
| Community highlights | 1x/week |
| Release announcements | Per release |
| Architecture threads | 2x/month |

**Algorithm mitigation**: Put GitHub link in reply, not main tweet. Use images of CLI output instead of plain text.

## Hacker News Strategy

See [show-hn-launch-strategy](/BAN/issues/BAN-7#document-show-hn-launch-strategy) for full details.

- **Show HN title**: "Show HN: shunt – An LLM load balancer that routes by KV cache, not just connections"
- **Post timing**: Tuesday-Thursday, 8-10 AM ET
- **Engagement**: Reply to every comment. Be technical. Show data. No marketing fluff.
- **Cross-promotion**: Link from Twitter/X thread, pin tweet

## r/LocalLLaMA Strategy

See [local-llama-strategy](/BAN/issues/BAN-7#document-local-llama-strategy) for full details.

- **Post format**: "I built an LLM load balancer that routes by KV cache state — shunt"
- **Timing**: 2-4 hours after Show HN, 9-11 AM ET weekday
- **Key difference from HN**: Emphasize "download and run in 30 seconds" over architecture
- **Engagement**: Reply to every comment within 2 hours. Be helpful even to critics.

## Content Calendar (Pre-Launch)

Week 1-2 focus: brand, voice, thought leadership. No product features until shunt has a working build.

| Week | Twitter/X | Other |
|------|-----------|-------|
| 1 | Company intro, manifesto thread, agent-first positioning | HN: monitor only |
| 2 | Build-in-public updates, Zig choice teaser, open source philosophy | Reddit: engage as community member (not about shunt) |
| 3 | Architecture decision threads, LLM infra hot takes | Reddit: answer LLM serving questions helpfully |
| 4 | Pre-launch anticipation, quick-start preview | HN: prepare Show HN draft |

## Failure Modes

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Zero engagement on early tweets | High | Engage with larger accounts' content first. Don't just broadcast. |
| X algorithm suppresses link tweets | Known issue | Put GitHub link in reply. Use images. |
| Build-in-public becomes vanity | Medium | Only post when something actually works. Run before you claim. |
| Negative quote-tweets from skeptics | Medium | Engage technically. Don't argue. |
| Account flagged for bot behavior | Low | Board/human posts, not automated tools. |
| Reddit post flagged as spam | Medium | Build account history first. Engage authentically on non-shunt topics. |
| "Why not nginx?" objection | Certain | Prepare honest comparison: nginx can't inspect KV cache state. |

## Success Metrics

| Metric | Target | Timeframe |
|--------|--------|-----------|
| Twitter/X followers | 500+ | Pre-launch |
| Show HN upvotes | 100+ | Launch day |
| r/LocalLLaMA upvotes | 100+ | Launch day |
| GitHub referral traffic | 500+ visits | Launch week |
| GitHub stars | 200+ | Launch week |

## Blocking Dependencies

- Twitter/X account: @ShitwareIndustr (active)
- Reddit account with history (needs organic activity before launch)
- Working shunt build (no product content until it actually runs)
