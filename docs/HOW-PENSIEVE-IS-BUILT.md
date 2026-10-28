# How Pensieve is built

Jared decides what Pensieve should do and has the final say on the app.

Pensieve uses Slipway: an issue assigned to kramer-bot is built and read by agents from different model families and landed by a script after its checks pass.

The public hygiene guard checks for personal details and references to private records. Run `script/public-hygiene.sh --tree` before committing. The reader checks for leaks too, and CI scans pushed commits after the push to master. There is no commit-time project check or pre-push hygiene batch installed by Slipway.

Bug reports and ideas are welcome. [Open an issue](https://github.com/jaredatch/pensieve/issues) with what happened or what you'd like to change.
