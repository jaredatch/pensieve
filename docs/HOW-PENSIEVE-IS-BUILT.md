# How Pensieve is built

Pensieve is made by one person and two AI agents. Jared decides what the app should be and has the final say on anything you can see. Claude plans the work and reviews it. Codex writes most of the code. Neither agent signs off on its own work, and neither can quietly move the goalposts.

That last part is the point of the whole setup. An agent that writes the code and the test for it will, sooner or later, write a test that passes because it was written to pass. Most of what follows exists to make that hard.

## Plans with frozen criteria

Anything bigger than a small fix starts as a plan: `PLAN-44`, say. A plan states its goal, splits the work into stages, and lists acceptance criteria as behavior you could observe, such as "after the guard can't read the index, it exits non-zero and names what it couldn't read". It doesn't prescribe the code.

Before anything is built, Codex reads the plan cold and argues with it. Wrong assumptions about the code, criteria that can't fail, gaps between stages. Claude folds in what holds up, and the criteria become the baseline.

Each criterion gets a check: a short script whose exit status says whether the behavior is there. Once every stage is built and reviewed, the criteria and their checks are frozen. A hash of them goes into the repository, and the commit hook refuses any change that doesn't match it. If a criterion turns out to be wrong after that, changing it is a separate, recorded step. Nobody can edit a criterion to fit what got built and hope it slips by.

Small changes, like a copy fix or a spacing tweak, skip the plan. They still get a test when behavior changes, and a changelog line when you'd notice the difference.

## Every check is proven twice

A check that has never failed proves nothing. So each check is run two ways before anyone trusts it:

1. Green on the real code.
2. Red on a copy where the behavior is deliberately broken. Someone deletes the line that refuses a bad input, say, or flips a condition.

The red run only counts if the break really landed and the check failed for the right reason. That means the named assertion, not a compile error or a typo in a path. Each check's green run, its mutation and its red run are recorded with the plan.

This catches more than you'd think. A test filter that matched nothing and passed anyway. A guard with two layers of defense, where breaking either layer alone left the check green.

## Reviews by the other model

Claude reviews the code Codex writes. Codex reviews anything Claude writes, including the plans and these docs. Before a plan freezes, the review covers each stage, then the whole branch, a security review and an adversarial pass on the riskiest surface. Findings go back to whoever built the code, and fixes get reviewed the same way. The loop runs until nothing blocking is left, eight rounds at most. Hitting the limit means stopping to ask a human.

Some checks can't be automated, like whether a screen matches its design, or whether a real release publishes. Those are manual gates, written down with what to look at. A release gate holds the plan open until it passes. A design check Jared hasn't gotten to becomes a tracked issue, so it can't be forgotten.

## The ratchet

A set of commit hooks, called the ratchet, runs on every commit, and CI replays them for each commit it builds.

- The test count can only go up. Deleting or skipping a test to get a green run is refused.
- Secret-shaped files and lines are refused.
- Frozen criteria can't change without the recorded refreeze step.
- The public hygiene guard keeps personal details and references to private records out of the repository.

## What you can see from here

The plans, the review records and the decision log live in a private repository. Commit messages and code comments mention plans and sprints by name, like `PLAN-44` or `sprint-6`. Each one matches a milestone on GitHub, which says what that work set out to do and which issues it closed.

None of this makes the app bug-free. It makes the bugs easier to catch before they ship, and harder to paper over when they do. If you find one, please [open an issue](https://github.com/jaredatch/pensieve/issues).
