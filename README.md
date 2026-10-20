# Soul Journal

A warlock's ledger of every soul trapped in a Soul Shard. Each captured soul appears as a
ghost sealed inside a crystal shard. You can page through them with the arrows or the mouse wheel.

- **Open:** right-click a Soul Shard in your bags, or type `/souls`
- **Records:** name, level at capture, elite/rare status, creature type (or race/class for players), zone, time, your level and the spell used (Drain Soul or Shadowburn)
- **Sparks:** a shard from a Drain Soul tick (before the kill) is a spark of that creature's soul and shows as a twinkling star on its crystal. If the creature dies some other way, its sparks stay in the journal without the soul
- **Bound vs. released:** when a shard is spent, sparks go first, then the oldest soul is marked released (shards can't be told apart, so first in, first out). Released souls show what took the shard: the spell (Create Healthstone, Ritual of Summoning, ...), or a vendor, trade or mail window
- **Keep:** tick "Keep this soul" on a bound soul to protect it. Kept souls and their sparks are passed over when shards are spent, and are released only once every other shard is gone
- `/souls clear` erases the journal (per character)

Built for **WoW Forever** (interface 16001) only.

## Releasing to CurseForge

1. Create the project at https://authors.curseforge.com (Game: World of Warcraft, Category: Class → Warlock).
2. The project ID (1754433) is set in `SoulJournal.toc` as `## X-Curse-Project-ID`.
3. Create an API token at https://authors.curseforge.com/account/api-tokens and save it as the GitHub repo secret `CF_API_KEY`.
4. Push a tag (`git tag v1.0.0 && git push --tags`). The workflow packages the addon with the BigWigs packager and uploads it.
