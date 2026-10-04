# Server folders and templates

Drag one server icon onto another to create a folder. Drop another server onto its folder button to add it. Click the folder to expand or collapse it. Open **Servers → Organize servers** to create or rename folders, move servers out, or ungroup them using a keyboard or phone. Folders belong to your account and synchronize between devices; they do not affect anyone else's servers or permissions. Conflicting saves reload the latest layout instead of overwriting another device's changes. Leaving a server removes it from the displayed folder, and newly joined servers appear outside folders.

On **Create server**, choose Blank, Friends, Gaming, Study group, or Community. Each template previews its text/voice channels and categories before creation. Existing servers still support **Add channel** and **Add category** from their navigation and server overview. Failed channel creation retains the form for retry.

Choose **Import from Discord or JSON** to preview a public `https://discord.new/CODE`, `https://discord.com/template/CODE`, or template code. Plainwire retrieves the public [Discord guild template](https://docs.discord.com/developers/resources/guild-template) through Discord's official API. No Discord account token is needed. You can also import a saved Discord template API response containing `serialized_source_guild`, or a Plainwire JSON template exported through **Server settings → Export server template**. The exported file contains channel names, topics, categories, role labels and colours, so review it before sharing it.

Imported structures support up to 100 text/voice channels, 25 categories and 50 role labels. Discord channels with any permission overrides, categories with overrides and their child channels are omitted conservatively; unsupported channel kinds and managed integration roles are omitted too. Duplicate Discord names receive numeric suffixes. The preview lists the supported structure and omissions. Templates are structure imports: they do not migrate messages, members, files, bots, webhooks or credentials.

**Imported servers start with default member permissions and imported role permissions set to zero.** The creator retains owner access. Review **Server settings → Roles → Default member permissions** and each role before inviting people or granting access. Plainwire uses additive server-wide capabilities, so Discord per-channel overrides are not transferred. The Friends/Gaming/Study/Community presets use Plainwire's normal member defaults; their names such as `rules` are channel names, without special access restrictions.

A Plainwire JSON template uses `format: "plainwire-server-template-v1"`, a name, and arrays of categories, channels and roles. Category references are zero-based indices into the categories array, or `null`. Channel kinds are `text` or `voice`; topics and slowmode are optional. Permissions provided in imported JSON are discarded. The server validates the structure again during creation, and creates it in one transaction.

Authenticated endpoints:

| Method and path | Behavior |
| --- | --- |
| `GET /api/server-layout` | Return your layout and current revision. |
| `POST /api/server-layout` | Save `{items, revision}`; stale revisions return HTTP 409. Items are `{server_id}` or `{id, name, server_ids, collapsed}`. Only joined server IDs are accepted. |
| `POST /api/server-templates/preview` | Validate and preview `{template}`, which is a preset name, a Plainwire structure, or a saved Discord template response. |
| `POST /api/server-templates/discord` | Fetch and preview `{code}` from the fixed official Discord endpoint. |
| `GET /api/server/:id/template` | Export structure; requires server management permission. |
| `POST /api/servers` | Accept an optional `template` returned by preview, alongside `name` and `description`. |

All writes require the normal session and CSRF checks. Folder labels use the instance's at-rest encryption settings. The Discord fetch accepts only strict template codes, pins a validated public address, verifies TLS, rejects redirects, and limits response size and request rates.

Migrations 58 and 59 add the group DM creation counter and account folder preferences. The counter initializes from existing owned groups, then increases for each new group, including custom named groups. Unnamed groups use `group dm 1`, `group dm 2`, and so on for their creator; ordinary one-to-one DMs do not consume a number. Leaving, renaming or deleting a newly created group does not reuse its number.
