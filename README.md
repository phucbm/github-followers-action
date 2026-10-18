# GitHub Followers to Discord

[![github stars](https://badgen.net/github/stars/phucbm/github-followers-action?icon=github)](https://github.com/phucbm/github-followers-action/)
[![github license](https://badgen.net/github/license/phucbm/github-followers-action?icon=github)](https://github.com/phucbm/github-followers-action/blob/main/LICENSE)
[![github marketplace](https://badgen.net/badge/github/marketplace/blue?icon=github)](https://github.com/marketplace/actions/github-followers-to-discord)
[![Made in Vietnam](https://raw.githubusercontent.com/webuild-community/badge/master/svg/made.svg)](https://webuild.community)

A GitHub Action that tells your Discord channel who followed and who unfollowed you on GitHub.

GitHub has no webhook for followers, so this action checks your follower list on a schedule, compares it with the last one, and posts each change.

---

## Setup

### Step 1 — Create a Discord webhook

1. In Discord, open the channel → **Edit Channel** → **Integrations** → **Webhooks**
2. Click **New Webhook**, give it a name and an avatar
3. Click **Copy Webhook URL**

### Step 2 — Add the webhook to GitHub Secrets

1. Go to your repo on GitHub → **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. Name: `DISCORD_WEBHOOK`, Value: paste the webhook URL
4. Save

Or from the terminal:

```bash
gh secret set DISCORD_WEBHOOK --repo <you>/<repo>
```

### Step 3 — Add the workflow file

Create `.github/workflows/followers.yml` in any repo you own (your profile repo `<you>/<you>` is a good home):

```yaml
name: Followers to Discord

on:
  schedule:
    - cron: '17 */6 * * *'  # Every 6 hours
  workflow_dispatch:        # Enables manual trigger via GitHub web

permissions:
  contents: write  # To commit the follower list

jobs:
  followers:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v6

      - name: Post follower changes to Discord
        uses: phucbm/github-followers-action@v1  # Docs https://github.com/phucbm/github-followers-action
        with:
          discord-webhook-url: ${{ secrets.DISCORD_WEBHOOK }}
```

### Step 4 — Run it once

Go to **Actions** → **Followers to Discord** → **Run workflow**.

The first run only saves your current followers to `.github/followers.json` and posts nothing, so you don't get a message for every follower you already have. From the next run on, each change is posted.

---

## How It Works

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│    FETCH    │───▶│   COMPARE   │───▶│    POST     │───▶│    SAVE     │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
       │                   │                   │                   │
       ▼                   ▼                   ▼                   ▼
   All followers       With the last       One card per        Commit the
   from the API        saved list          change, or one      new list, only
                       (first run:         summary above       when it changed
                       save only)          max-messages
```

Each new follower gets a green card and each unfollower a red one, with their avatar, name, bio, followers and repos, and your new total in the footer.

**Safe by default**

- **First run** saves the list and posts nothing.
- **A bad API response** (an empty list while your profile shows followers) changes nothing, so it never reads as everyone unfollowing you.
- **A burst of changes** above `max-messages` (default 10) is posted as one summary instead of a flood.
- **A deleted account** among the unfollowers still gets a card, marked as gone.
- **No commit** when nothing changed.

---

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `discord-webhook-url` | Discord webhook URL. **Required.** Store it as a secret. | — |
| `username` | GitHub user whose followers are tracked | the repo owner |
| `github-token` | GitHub token used to read the follower list | `${{ github.token }}` |
| `state-file` | JSON file that keeps the last known followers | `.github/followers.json` |
| `notify-follows` | Post new followers | `true` |
| `notify-unfollows` | Post unfollowers | `true` |
| `max-messages` | Above this many changes, post one summary | `10` |
| `commit-state` | Commit and push the state file when it changes | `true` |
| `dry-run` | Print the messages instead of posting, and don't commit | `false` |

## Outputs

| Output | Description |
|--------|-------------|
| `followers` | Current number of followers |
| `new-followers` | Comma-separated logins of new followers |
| `unfollowers` | Comma-separated logins of unfollowers |
| `first-run` | Whether this run only saved the starting list |

---

## Advanced Usage

All available options (enable only what you need):

```yaml
- name: Post follower changes to Discord
  uses: phucbm/github-followers-action@v1
  with:
    discord-webhook-url: ${{ secrets.DISCORD_WEBHOOK }}
    # username: 'someone-else'
    # github-token: ${{ secrets.CUSTOM_TOKEN }}
    # state-file: 'data/followers.json'
    # notify-follows: 'true'
    # notify-unfollows: 'false'
    # max-messages: '5'
    # commit-state: 'true'
    # dry-run: 'true'
```

### Using outputs

```yaml
- name: Post follower changes to Discord
  id: followers
  uses: phucbm/github-followers-action@v1
  with:
    discord-webhook-url: ${{ secrets.DISCORD_WEBHOOK }}

- name: Show changes
  run: |
    echo "Followers: ${{ steps.followers.outputs.followers }}"
    echo "New: ${{ steps.followers.outputs.new-followers }}"
    echo "Gone: ${{ steps.followers.outputs.unfollowers }}"
```

### How often to run

Every 6 hours is plenty for most accounts. GitHub often starts scheduled runs some minutes late, so a tighter schedule isn't more precise. A run takes a few seconds, and Actions minutes are free on public repos.

---

## Troubleshooting

**Nothing posted on the first run** — That's expected: the first run only saves your current followers.

**Permission denied when pushing** — Ensure `contents: write` is set in your workflow permissions, and `actions/checkout` runs before this action.

**Discord answered 401 or 404** — The webhook URL is wrong or the webhook was deleted. Copy a new one into the `DISCORD_WEBHOOK` secret.

**The schedule stopped** — GitHub disables scheduled workflows in a public repo with no activity for 60 days. Each follower change commits the state file, which counts as activity; after a long quiet spell, re-enable the workflow from the **Actions** tab.

**Using it on a private repo** — It works the same; scheduled runs then count against your Actions minutes.

---

## License

MIT License - feel free to use in your projects!
