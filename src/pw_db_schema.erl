-module(pw_db_schema).
-export([migrations/0]).

%% Ordered PostgreSQL migrations. pw_db applies these under one advisory lock.
%% The statements are data: changing one changes the database, so this module
%% only holds the list.

migrations() -> [
    {1, [
        "CREATE TABLE IF NOT EXISTS users(id serial PRIMARY KEY, username text UNIQUE NOT NULL, display_name text NOT NULL, "
        "password_hash text NOT NULL, password_salt text NOT NULL, bio text NOT NULL DEFAULT '', avatar_url text NOT NULL DEFAULT '', "
        "banner_url text NOT NULL DEFAULT '', status text NOT NULL DEFAULT '', theme text NOT NULL DEFAULT 'system', "
        "created_at bigint NOT NULL, updated_at bigint NOT NULL, last_seen bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS sessions(token_hash text PRIMARY KEY, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "csrf text NOT NULL, created_at bigint NOT NULL, expires_at bigint NOT NULL, last_seen bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS forums(id serial PRIMARY KEY, slug text UNIQUE NOT NULL, name text NOT NULL, description text NOT NULL, position integer NOT NULL)",
        "CREATE TABLE IF NOT EXISTS forum_members(forum_id integer NOT NULL REFERENCES forums(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, joined_at bigint NOT NULL, PRIMARY KEY(forum_id, user_id))",
        "CREATE TABLE IF NOT EXISTS threads(id serial PRIMARY KEY, forum_id integer NOT NULL REFERENCES forums(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id), title text NOT NULL, body text NOT NULL, created_at bigint NOT NULL, "
        "updated_at bigint NOT NULL, reply_count integer NOT NULL DEFAULT 0, locked boolean NOT NULL DEFAULT false, "
        "pinned boolean NOT NULL DEFAULT false, views integer NOT NULL DEFAULT 0, score integer NOT NULL DEFAULT 0, "
        "upvotes integer NOT NULL DEFAULT 0, downvotes integer NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS replies(id serial PRIMARY KEY, thread_id integer NOT NULL REFERENCES threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id), body text NOT NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS friendships(user_low integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "user_high integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, requester_id integer NOT NULL REFERENCES users(id), "
        "addressee_id integer NOT NULL REFERENCES users(id), status text NOT NULL CHECK(status IN ('pending','accepted','blocked')), "
        "created_at bigint NOT NULL, updated_at bigint NOT NULL, PRIMARY KEY(user_low, user_high))",
        "CREATE TABLE IF NOT EXISTS servers(id serial PRIMARY KEY, owner_id integer NOT NULL REFERENCES users(id), name text NOT NULL, "
        "description text NOT NULL, icon_url text NOT NULL DEFAULT '', created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS server_members(server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, role text NOT NULL DEFAULT 'member', "
        "muted boolean NOT NULL DEFAULT false, joined_at bigint NOT NULL, PRIMARY KEY(server_id, user_id))",
        "CREATE TABLE IF NOT EXISTS channels(id serial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "name text NOT NULL, kind text NOT NULL CHECK(kind IN ('text','voice')), position integer NOT NULL, topic text NOT NULL DEFAULT '', "
        "created_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS direct_threads(id serial PRIMARY KEY, name text NOT NULL DEFAULT '', avatar_url text NOT NULL DEFAULT '', "
        "owner_id integer NOT NULL REFERENCES users(id), created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS direct_members(thread_id integer NOT NULL REFERENCES direct_threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, last_read_message_id integer NOT NULL DEFAULT 0, "
        "muted boolean NOT NULL DEFAULT false, nickname text NOT NULL DEFAULT '', joined_at bigint NOT NULL, "
        "PRIMARY KEY(thread_id, user_id))",
        "CREATE TABLE IF NOT EXISTS messages(id serial PRIMARY KEY, scope text NOT NULL CHECK(scope IN ('channel','direct')), "
        "scope_id integer NOT NULL, user_id integer NOT NULL REFERENCES users(id), body text NOT NULL, reply_to_id integer, "
        "created_at bigint NOT NULL, edited_at bigint, deleted_at bigint)",
        "CREATE TABLE IF NOT EXISTS notifications(id serial PRIMARY KEY, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "kind text NOT NULL, body text NOT NULL, url text NOT NULL, seen boolean NOT NULL DEFAULT false, created_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS server_invites(code text PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "channel_id integer, creator_id integer NOT NULL REFERENCES users(id), max_uses integer NOT NULL DEFAULT 0, uses integer NOT NULL DEFAULT 0, "
        "created_at bigint NOT NULL, expires_at bigint NOT NULL DEFAULT 0, revoked boolean NOT NULL DEFAULT false)",
        "CREATE INDEX IF NOT EXISTS idx_threads_forum ON threads(forum_id, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_forum_members_user ON forum_members(user_id, forum_id)",
        "CREATE INDEX IF NOT EXISTS idx_replies_thread ON replies(thread_id, created_at)",
        "CREATE INDEX IF NOT EXISTS idx_messages_scope ON messages(scope, scope_id, id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, seen, id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_direct_members_user ON direct_members(user_id, thread_id)",
        "CREATE INDEX IF NOT EXISTS idx_server_members_user ON server_members(user_id, server_id)",
        "CREATE INDEX IF NOT EXISTS idx_invites_server ON server_invites(server_id, revoked)",
        "CREATE TABLE IF NOT EXISTS thread_votes(thread_id integer NOT NULL REFERENCES threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, value integer NOT NULL CHECK(value IN (-1, 1)), "
        "created_at bigint NOT NULL, PRIMARY KEY(thread_id, user_id))",
        "CREATE INDEX IF NOT EXISTS idx_thread_votes_user ON thread_votes(user_id, thread_id)"
    ]},
    {2, [
        "CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(scope, scope_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_users_last_seen ON users(last_seen DESC)"
    ]},
    {3, [
        "ALTER TABLE threads ADD COLUMN IF NOT EXISTS score integer NOT NULL DEFAULT 0",
        "ALTER TABLE threads ADD COLUMN IF NOT EXISTS upvotes integer NOT NULL DEFAULT 0",
        "ALTER TABLE threads ADD COLUMN IF NOT EXISTS downvotes integer NOT NULL DEFAULT 0",
        "CREATE TABLE IF NOT EXISTS thread_votes(thread_id integer NOT NULL REFERENCES threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, value integer NOT NULL CHECK(value IN (-1, 1)), "
        "created_at bigint NOT NULL, PRIMARY KEY(thread_id, user_id))",
        "CREATE INDEX IF NOT EXISTS idx_thread_votes_user ON thread_votes(user_id, thread_id)"
    ]},
    {4, [
        "CREATE TABLE IF NOT EXISTS forum_members(forum_id integer NOT NULL REFERENCES forums(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, joined_at bigint NOT NULL, PRIMARY KEY(forum_id, user_id))",
        "CREATE INDEX IF NOT EXISTS idx_forum_members_user ON forum_members(user_id, forum_id)"
    ]},
    {5, [
        "ALTER TABLE direct_members ADD COLUMN IF NOT EXISTS request_state text NOT NULL DEFAULT 'accepted'",
        "ALTER TABLE direct_members DROP CONSTRAINT IF EXISTS direct_members_request_state_check",
        "ALTER TABLE direct_members ADD CONSTRAINT direct_members_request_state_check CHECK(request_state IN ('pending','accepted'))",
        "CREATE INDEX IF NOT EXISTS idx_direct_members_requests ON direct_members(user_id, request_state, joined_at DESC)"
    ]},
    {6, [
        "CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON notifications(user_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_messages_reply_to ON messages(reply_to_id) WHERE reply_to_id IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_channels_server ON channels(server_id, position ASC, id ASC)"
    ]},
    {7, [
        "CREATE TABLE IF NOT EXISTS uploads(id text PRIMARY KEY, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "name text NOT NULL, content_type text NOT NULL, size bigint NOT NULL CHECK(size > 0 AND size <= 262144000), "
        "path text NOT NULL, status text NOT NULL CHECK(status IN ('pending','ready')), sha256 text NOT NULL DEFAULT '', created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_uploads_user_created ON uploads(user_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_uploads_pending ON uploads(created_at) WHERE status = 'pending'"
    ]},
    {8, [
        "ALTER TABLE direct_members ADD COLUMN IF NOT EXISTS hidden boolean NOT NULL DEFAULT false"
    ]},
    {9, [
        "ALTER TABLE forums ADD COLUMN IF NOT EXISTS owner_id integer REFERENCES users(id) ON DELETE SET NULL",
        "UPDATE forums f SET owner_id = (SELECT fm.user_id FROM forum_members fm WHERE fm.forum_id = f.id ORDER BY fm.joined_at ASC LIMIT 1) "
        "WHERE f.owner_id IS NULL AND f.slug NOT IN ('general','support','development','security')",
        "CREATE TABLE IF NOT EXISTS thread_views(thread_id integer NOT NULL REFERENCES threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, first_viewed_at bigint NOT NULL, "
        "PRIMARY KEY(thread_id,user_id))",
        "CREATE INDEX IF NOT EXISTS idx_thread_views_user ON thread_views(user_id,thread_id)",
        "UPDATE threads SET views = 0"
    ]},
    %% old uploads had no ACL. refs add one without trying to query ciphertext.
    {10, [
        "CREATE TABLE IF NOT EXISTS upload_refs(upload_id text NOT NULL REFERENCES uploads(id) ON DELETE CASCADE, "
        "scope text NOT NULL CHECK(scope IN ('channel','direct','profile')), scope_id integer NOT NULL, "
        "created_at bigint NOT NULL, PRIMARY KEY(upload_id, scope, scope_id))",
        "CREATE INDEX IF NOT EXISTS idx_upload_refs_upload ON upload_refs(upload_id)",
        "CREATE TABLE IF NOT EXISTS upload_ref_backfill(id integer PRIMARY KEY, cursor integer NOT NULL DEFAULT 0, "
        "done boolean NOT NULL DEFAULT false)",
        "INSERT INTO upload_ref_backfill(id, cursor, done) VALUES(1, 0, false) ON CONFLICT (id) DO NOTHING",
        %% profile pictures are public refs.
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'profile', u.id, 0 FROM users u JOIN uploads up ON up.id = substring(u.avatar_url from 12) "
        "WHERE u.avatar_url LIKE '/api/files/%' ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'profile', u.id, 0 FROM users u JOIN uploads up ON up.id = substring(u.banner_url from 12) "
        "WHERE u.banner_url LIKE '/api/files/%' ON CONFLICT DO NOTHING"
    ]},
    {11, [
        "CREATE TABLE IF NOT EXISTS channel_categories(id serial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "name text NOT NULL, position integer NOT NULL, created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_channel_categories_server ON channel_categories(server_id, position ASC, id ASC)",
        "ALTER TABLE channels ADD COLUMN IF NOT EXISTS category_id integer REFERENCES channel_categories(id) ON DELETE SET NULL"
    ]},
    {12, [
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS banner_url text NOT NULL DEFAULT ''",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS accent_color text NOT NULL DEFAULT '#5865f2'"
    ]},
    {13, [
        "ALTER TABLE upload_refs DROP CONSTRAINT IF EXISTS upload_refs_scope_check",
        "ALTER TABLE upload_refs ADD CONSTRAINT upload_refs_scope_check CHECK(scope IN ('channel','direct','profile','server'))",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'server', s.id, 0 FROM servers s JOIN uploads up ON up.id = substring(s.icon_url from 12) "
        "WHERE s.icon_url LIKE '/api/files/%' ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'server', s.id, 0 FROM servers s JOIN uploads up ON up.id = substring(s.banner_url from 12) "
        "WHERE s.banner_url LIKE '/api/files/%' ON CONFLICT DO NOTHING"
    ]},
    {14, [
        "ALTER TABLE sessions ADD COLUMN IF NOT EXISTS id bigserial",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_id ON sessions(id)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_user_last_seen ON sessions(user_id, last_seen DESC)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_expiry ON sessions(expires_at)"
    ]},
    {15, [
        "ALTER TABLE users ALTER COLUMN theme SET DEFAULT 'system'"
    ]},
    {16, [
        "CREATE INDEX IF NOT EXISTS idx_friendships_low_updated ON friendships(user_low, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_friendships_high_updated ON friendships(user_high, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_upload_refs_scope_lookup ON upload_refs(scope, scope_id, upload_id)",
        "CREATE INDEX IF NOT EXISTS idx_direct_members_thread_request ON direct_members(thread_id, request_state, user_id)",
        "CREATE INDEX IF NOT EXISTS idx_server_members_server_role ON server_members(server_id, role, user_id)"
    ]},
    {17, [
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS welcome_message text NOT NULL DEFAULT ''"
    ]},
    {18, [
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'text'",
        "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check",
        "ALTER TABLE messages ADD CONSTRAINT messages_kind_check CHECK(kind IN ('text','missed_call'))"
    ]},
    {19, [
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS forwarded_from_id integer REFERENCES messages(id) ON DELETE SET NULL",
        "CREATE INDEX IF NOT EXISTS idx_messages_forwarded_from ON messages(forwarded_from_id) WHERE forwarded_from_id IS NOT NULL"
    ]},
    {20, [
        "CREATE TABLE IF NOT EXISTS server_roles(id bigserial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "name text NOT NULL, color text NOT NULL DEFAULT '#99aab5', permissions bigint NOT NULL DEFAULT 0, position integer NOT NULL DEFAULT 1, "
        "hoist boolean NOT NULL DEFAULT false, mentionable boolean NOT NULL DEFAULT false, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_server_roles_name_unique ON server_roles(server_id, lower(name))",
        "CREATE INDEX IF NOT EXISTS idx_server_roles_order ON server_roles(server_id, position DESC, id ASC)",
        "CREATE TABLE IF NOT EXISTS server_member_roles(server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, role_id bigint NOT NULL REFERENCES server_roles(id) ON DELETE CASCADE, "
        "assigned_by integer REFERENCES users(id) ON DELETE SET NULL, assigned_at bigint NOT NULL, PRIMARY KEY(server_id,user_id,role_id))",
        "CREATE INDEX IF NOT EXISTS idx_server_member_roles_user ON server_member_roles(server_id,user_id,role_id)",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS nickname text NOT NULL DEFAULT ''",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS avatar_url text NOT NULL DEFAULT ''",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS bio text NOT NULL DEFAULT ''",
        "ALTER TABLE direct_members ADD COLUMN IF NOT EXISTS group_role text NOT NULL DEFAULT 'member'",
        "ALTER TABLE direct_members DROP CONSTRAINT IF EXISTS direct_members_group_role_check",
        "ALTER TABLE direct_members ADD CONSTRAINT direct_members_group_role_check CHECK(group_role IN ('owner','moderator','member'))",
        "UPDATE direct_members dm SET group_role = 'owner' FROM direct_threads dt WHERE dm.thread_id = dt.id AND dm.user_id = dt.owner_id",
        "CREATE INDEX IF NOT EXISTS idx_direct_members_group_role ON direct_members(thread_id,group_role,user_id)"
    ]},
    {21, [
        "ALTER TABLE threads ADD COLUMN IF NOT EXISTS raw_body text NOT NULL DEFAULT ''",
        "UPDATE threads SET raw_body = body WHERE raw_body = ''",
        "ALTER TABLE replies ADD COLUMN IF NOT EXISTS raw_body text NOT NULL DEFAULT ''",
        "UPDATE replies SET raw_body = body WHERE raw_body = ''"
    ]},
    {22, [
        %% Existing accounts have already learned the interface. Only accounts created
        %% after this migration enter the automatic welcome tour (registration sets pending).
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS onboarding_state text NOT NULL DEFAULT 'complete'",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS onboarding_step integer NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS onboarding_updated_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_onboarding_state_check",
        "ALTER TABLE users ADD CONSTRAINT users_onboarding_state_check CHECK(onboarding_state IN ('pending','active','complete','dismissed'))",
        "CREATE INDEX IF NOT EXISTS idx_users_onboarding_state ON users(onboarding_state)"
    ]},
    {23, [
        %% 771 is the historical ordinary-member baseline: view channels, send
        %% messages, create Wires, and connect to voice. Storing it per server lets
        %% owners tighten that baseline without breaking existing installations.
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS default_permissions bigint NOT NULL DEFAULT 771"
    ]},
    {24, [
        %% Thread composers support the same /api/files attachments as chat. Keep
        %% their ACL references explicit so non-author readers can fetch them.
        "ALTER TABLE upload_refs DROP CONSTRAINT IF EXISTS upload_refs_scope_check",
        "ALTER TABLE upload_refs ADD CONSTRAINT upload_refs_scope_check CHECK(scope IN ('channel','direct','profile','server','thread'))",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'thread', t.id, 0 FROM threads t "
        "CROSS JOIN LATERAL regexp_matches(COALESCE(NULLIF(t.raw_body,''),t.body), '/api/files/([A-Za-z0-9_-]{24,64})', 'g') AS rx(parts) "
        "JOIN uploads up ON up.id = rx.parts[1] ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'thread', r.thread_id, 0 FROM replies r "
        "CROSS JOIN LATERAL regexp_matches(COALESCE(NULLIF(r.raw_body,''),r.body), '/api/files/([A-Za-z0-9_-]{24,64})', 'g') AS rx(parts) "
        "JOIN uploads up ON up.id = rx.parts[1] ON CONFLICT DO NOTHING"
    ]},
    {25, [
        %% Rebuild every derived ACL relation once so stale references from profile/
        %% server image replacement or edited/deleted content cannot survive an
        %% upgrade. Message bodies may be encrypted, so channel/direct refs are
        %% rebuilt by the resumable application backfill after this migration.
        "DELETE FROM upload_refs WHERE scope IN ('channel','direct','profile','server','thread')",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'profile', u.id, 0 FROM users u JOIN uploads up ON "
        "(u.avatar_url = '/api/files/' || up.id OR u.banner_url = '/api/files/' || up.id) "
        "ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'server', s.id, 0 FROM servers s JOIN uploads up ON "
        "(s.icon_url = '/api/files/' || up.id OR s.banner_url = '/api/files/' || up.id) "
        "ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'thread', t.id, 0 FROM threads t "
        "CROSS JOIN LATERAL regexp_matches(COALESCE(NULLIF(t.raw_body,''),t.body), '/api/files/([A-Za-z0-9_-]{24,64})', 'g') AS rx(parts) "
        "JOIN uploads up ON up.id = rx.parts[1] ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'thread', r.thread_id, 0 FROM replies r "
        "CROSS JOIN LATERAL regexp_matches(COALESCE(NULLIF(r.raw_body,''),r.body), '/api/files/([A-Za-z0-9_-]{24,64})', 'g') AS rx(parts) "
        "JOIN uploads up ON up.id = rx.parts[1] ON CONFLICT DO NOTHING",
        "INSERT INTO upload_ref_backfill(id, cursor, done) VALUES(1, 0, false) ON CONFLICT (id) DO NOTHING",
        "UPDATE upload_ref_backfill SET cursor = 0, done = false WHERE id = 1"
    ]},
    {26, [
        %% Server-scoped member avatars are private to server members. Group-DM
        %% avatars reuse the direct scope so all current conversation members can
        %% fetch them. Backfill both so upgrading does not leave broken images.
        "ALTER TABLE upload_refs DROP CONSTRAINT IF EXISTS upload_refs_scope_check",
        "ALTER TABLE upload_refs ADD CONSTRAINT upload_refs_scope_check CHECK(scope IN ('channel','direct','profile','server','thread','server_member'))",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'server_member', sm.server_id, 0 FROM server_members sm JOIN uploads up ON "
        "sm.avatar_url = '/api/files/' || up.id ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'direct', dt.id, 0 FROM direct_threads dt JOIN uploads up ON "
        "dt.avatar_url = '/api/files/' || up.id ON CONFLICT DO NOTHING"
    ]},
    {27, [
        %% Compatibility repair for installations that were upgraded by older
        %% non-transactional migration code. Every statement is idempotent; the
        %% normal ordered migrations remain authoritative for healthy installs.
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS bio text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS banner_url text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS theme text NOT NULL DEFAULT 'system'",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS created_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS last_seen bigint NOT NULL DEFAULT 0",
        "ALTER TABLE friendships ADD COLUMN IF NOT EXISTS created_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE friendships ADD COLUMN IF NOT EXISTS updated_at bigint NOT NULL DEFAULT 0",
        "CREATE INDEX IF NOT EXISTS idx_friendships_low_updated ON friendships(user_low, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_friendships_high_updated ON friendships(user_high, updated_at DESC)",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS banner_url text NOT NULL DEFAULT ''",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS accent_color text NOT NULL DEFAULT '#5865f2'",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS welcome_message text NOT NULL DEFAULT ''",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS default_permissions bigint NOT NULL DEFAULT 771",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS nickname text NOT NULL DEFAULT ''",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS avatar_url text NOT NULL DEFAULT ''",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS bio text NOT NULL DEFAULT ''",
        "CREATE TABLE IF NOT EXISTS channel_categories(id serial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, name text NOT NULL, position integer NOT NULL, created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_channel_categories_server ON channel_categories(server_id, position ASC, id ASC)",
        "ALTER TABLE channels ADD COLUMN IF NOT EXISTS category_id integer REFERENCES channel_categories(id) ON DELETE SET NULL",
        "CREATE TABLE IF NOT EXISTS server_roles(id bigserial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, name text NOT NULL, color text NOT NULL DEFAULT '#99aab5', permissions bigint NOT NULL DEFAULT 0, position integer NOT NULL DEFAULT 1, hoist boolean NOT NULL DEFAULT false, mentionable boolean NOT NULL DEFAULT false, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS color text NOT NULL DEFAULT '#99aab5'",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS permissions bigint NOT NULL DEFAULT 0",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS position integer NOT NULL DEFAULT 1",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS hoist boolean NOT NULL DEFAULT false",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS mentionable boolean NOT NULL DEFAULT false",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS created_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS updated_at bigint NOT NULL DEFAULT 0",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_server_roles_name_unique ON server_roles(server_id, lower(name))",
        "CREATE INDEX IF NOT EXISTS idx_server_roles_order ON server_roles(server_id, position DESC, id ASC)",
        "CREATE TABLE IF NOT EXISTS server_member_roles(server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, role_id bigint NOT NULL REFERENCES server_roles(id) ON DELETE CASCADE, assigned_by integer REFERENCES users(id) ON DELETE SET NULL, assigned_at bigint NOT NULL DEFAULT 0, PRIMARY KEY(server_id,user_id,role_id))",
        "ALTER TABLE server_member_roles ADD COLUMN IF NOT EXISTS assigned_by integer REFERENCES users(id) ON DELETE SET NULL",
        "ALTER TABLE server_member_roles ADD COLUMN IF NOT EXISTS assigned_at bigint NOT NULL DEFAULT 0",
        "CREATE INDEX IF NOT EXISTS idx_server_member_roles_user ON server_member_roles(server_id,user_id,role_id)"
    ]},
    {28, [
        "CREATE TABLE IF NOT EXISTS message_reactions(message_id integer NOT NULL REFERENCES messages(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, emoji text NOT NULL, created_at bigint NOT NULL, "
        "PRIMARY KEY(message_id,user_id,emoji), CHECK(char_length(emoji) BETWEEN 1 AND 16))",
        "CREATE INDEX IF NOT EXISTS idx_message_reactions_message ON message_reactions(message_id,created_at ASC)",
        "CREATE INDEX IF NOT EXISTS idx_message_reactions_user ON message_reactions(user_id,message_id)"
    ]},
    {29, [
        "CREATE TABLE IF NOT EXISTS admin_operators(user_id integer PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, "
        "role text NOT NULL CHECK(role IN ('owner','operator','viewer')), verification_hash text NOT NULL, "
        "created_by integer REFERENCES users(id) ON DELETE SET NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS admin_sessions(token_hash text PRIMARY KEY, user_id integer NOT NULL REFERENCES admin_operators(user_id) ON DELETE CASCADE, "
        "csrf text NOT NULL, created_at bigint NOT NULL, last_seen bigint NOT NULL, expires_at bigint NOT NULL, "
        "ip_hash text NOT NULL DEFAULT '', user_agent_hash text NOT NULL DEFAULT '')",
        "CREATE INDEX IF NOT EXISTS idx_admin_sessions_user ON admin_sessions(user_id,expires_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_admin_sessions_expiry ON admin_sessions(expires_at)",
        "CREATE TABLE IF NOT EXISTS admin_enrollments(token_hash text PRIMARY KEY, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "role text NOT NULL CHECK(role IN ('owner','operator','viewer')), created_by integer REFERENCES admin_operators(user_id) ON DELETE CASCADE, "
        "note text NOT NULL DEFAULT '', created_at bigint NOT NULL, expires_at bigint NOT NULL, used_at bigint)",
        "CREATE INDEX IF NOT EXISTS idx_admin_enrollments_user ON admin_enrollments(user_id,expires_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_admin_enrollments_creator_unused ON admin_enrollments(created_by) WHERE used_at IS NULL",
        "CREATE TABLE IF NOT EXISTS admin_audit(id bigserial PRIMARY KEY, actor_user_id integer REFERENCES users(id) ON DELETE SET NULL, "
        "action text NOT NULL, target_type text NOT NULL DEFAULT '', target_id text NOT NULL DEFAULT '', detail text NOT NULL DEFAULT '', "
        "ip_hash text NOT NULL DEFAULT '', created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_admin_audit_created ON admin_audit(created_at DESC,id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_messages_created_global ON messages(created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_messages_user ON messages(user_id,id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_expiry ON sessions(expires_at)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_user_expiry ON sessions(user_id,expires_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_uploads_user_status ON uploads(user_id,status)"
    ]},
    {30, [
        "CREATE TABLE IF NOT EXISTS global_banners(id bigserial PRIMARY KEY, title text NOT NULL DEFAULT '', body text NOT NULL, "
        "severity text NOT NULL CHECK(severity IN ('info','success','warning','critical')), starts_at bigint NOT NULL CHECK(starts_at>=0), "
        "ends_at bigint NOT NULL DEFAULT 0 CHECK(ends_at=0 OR ends_at>starts_at), "
        "dismissible boolean NOT NULL DEFAULT true, link_label text NOT NULL DEFAULT '', link_url text NOT NULL DEFAULT '', enabled boolean NOT NULL DEFAULT true, "
        "created_by integer REFERENCES users(id) ON DELETE SET NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_global_banners_window ON global_banners(enabled,starts_at,ends_at,id)",
        "CREATE INDEX IF NOT EXISTS idx_global_banners_updated ON global_banners(updated_at DESC,id DESC)",
        "CREATE TABLE IF NOT EXISTS instance_settings(key text PRIMARY KEY, value text NOT NULL, updated_by integer REFERENCES users(id) ON DELETE SET NULL, updated_at bigint NOT NULL)",
        "INSERT INTO instance_settings(key,value,updated_by,updated_at) VALUES('registration_mode','inherit',NULL,0) ON CONFLICT(key) DO NOTHING"
    ]}
    ,{31, [
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS account_state text NOT NULL DEFAULT 'active'",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS disabled_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_account_state_check",
        "ALTER TABLE users ADD CONSTRAINT users_account_state_check CHECK(account_state IN ('active','disabled'))",
        "CREATE INDEX IF NOT EXISTS idx_users_account_state ON users(account_state,id)"
    ]}
    ,{32, [
        "CREATE TABLE IF NOT EXISTS server_webhooks(id bigserial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, name text NOT NULL, url text NOT NULL, secret text NOT NULL, events text NOT NULL, enabled boolean NOT NULL DEFAULT true, created_by integer REFERENCES users(id) ON DELETE SET NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL, last_success_at bigint NOT NULL DEFAULT 0, last_failure_at bigint NOT NULL DEFAULT 0, failure_count integer NOT NULL DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS idx_server_webhooks_server ON server_webhooks(server_id,id)",
        "CREATE TABLE IF NOT EXISTS webhook_deliveries(id bigserial PRIMARY KEY, webhook_id bigint NOT NULL REFERENCES server_webhooks(id) ON DELETE CASCADE, event text NOT NULL, payload bytea NOT NULL, status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','delivered','failed')), attempts integer NOT NULL DEFAULT 0, next_attempt_at bigint NOT NULL, locked_at bigint NOT NULL DEFAULT 0, response_code integer NOT NULL DEFAULT 0, last_error text NOT NULL DEFAULT '', created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_due ON webhook_deliveries(status,next_attempt_at,id)",
        "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_webhook ON webhook_deliveries(webhook_id,id DESC)"
    ]}

    ,{33, [
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS is_bot boolean NOT NULL DEFAULT false",
        "CREATE INDEX IF NOT EXISTS idx_users_is_bot ON users(is_bot,id) WHERE is_bot=true",
        "CREATE TABLE IF NOT EXISTS server_bots(id bigserial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, bot_user_id integer NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE, name text NOT NULL, token_hash text NOT NULL UNIQUE, created_by integer REFERENCES users(id) ON DELETE SET NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_server_bots_server ON server_bots(server_id,id)"
    ]}
    ,{34, [
        %% 1.x default members could already attach files, react, and stream. 2.0
        %% gives those existing behaviors explicit permission bits and enables the
        %% new voice-note bit for untouched default servers. Customized permission
        %% masks are deliberately left alone.
        "ALTER TABLE servers ALTER COLUMN default_permissions SET DEFAULT 59139",
        "UPDATE servers SET default_permissions=59139 WHERE default_permissions=771"
    ]}
    ,{35, [
        %% Message IDs move off PostgreSQL sequences. Widen every reference first,
        %% then the primary key, and recreate the two explicit message FKs.
        "ALTER TABLE message_reactions DROP CONSTRAINT IF EXISTS message_reactions_message_id_fkey",
        "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_reply_to_id_fkey",
        "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_forwarded_from_id_fkey",
        "ALTER TABLE message_reactions ALTER COLUMN message_id TYPE bigint USING message_id::bigint",
        "ALTER TABLE direct_members ALTER COLUMN last_read_message_id TYPE bigint USING last_read_message_id::bigint",
        "ALTER TABLE messages ALTER COLUMN reply_to_id TYPE bigint USING reply_to_id::bigint",
        "ALTER TABLE messages ALTER COLUMN forwarded_from_id TYPE bigint USING forwarded_from_id::bigint",
        "ALTER TABLE messages ALTER COLUMN id TYPE bigint USING id::bigint",
        "ALTER TABLE messages ALTER COLUMN id DROP DEFAULT",
        "ALTER TABLE message_reactions ADD CONSTRAINT message_reactions_message_id_fkey FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE",
        "ALTER TABLE messages ADD CONSTRAINT messages_reply_to_id_fkey FOREIGN KEY(reply_to_id) REFERENCES messages(id) ON DELETE SET NULL",
        "ALTER TABLE messages ADD CONSTRAINT messages_forwarded_from_id_fkey FOREIGN KEY(forwarded_from_id) REFERENCES messages(id) ON DELETE SET NULL",
        "CREATE TABLE IF NOT EXISTS message_id_node_leases(node_id smallint PRIMARY KEY CHECK(node_id BETWEEN 0 AND 63), node_name text NOT NULL, lease_until bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_message_id_node_leases_expiry ON message_id_node_leases(lease_until)",
        "CREATE TABLE IF NOT EXISTS storage_outbox(id bigserial PRIMARY KEY, kind text NOT NULL, entity_id bigint NOT NULL DEFAULT 0, payload bytea NOT NULL, status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','delivered','failed')), attempts integer NOT NULL DEFAULT 0, next_attempt_at bigint NOT NULL DEFAULT 0, locked_at bigint NOT NULL DEFAULT 0, last_error text NOT NULL DEFAULT '', created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_storage_outbox_due ON storage_outbox(status,next_attempt_at,id)",
        "CREATE INDEX IF NOT EXISTS idx_storage_outbox_entity ON storage_outbox(kind,entity_id,id DESC)",
        "CREATE TABLE IF NOT EXISTS storage_migration_checkpoints(name text PRIMARY KEY, last_id bigint NOT NULL DEFAULT 0, rows_done bigint NOT NULL DEFAULT 0, updated_at bigint NOT NULL)",
        "INSERT INTO storage_migration_checkpoints(name,last_id,rows_done,updated_at) VALUES('messages',0,0,0) ON CONFLICT(name) DO NOTHING"
    ]}
    ,{36, [
        "CREATE TABLE IF NOT EXISTS server_bans(server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, banned_by integer REFERENCES users(id) ON DELETE SET NULL, reason text NOT NULL DEFAULT '', created_at bigint NOT NULL, PRIMARY KEY(server_id,user_id))",
        "CREATE INDEX IF NOT EXISTS idx_server_bans_user ON server_bans(user_id,server_id)",
        "CREATE INDEX IF NOT EXISTS idx_server_bans_server_created ON server_bans(server_id,created_at DESC,user_id)"
    ]}
    ,{37, [
        "CREATE TABLE IF NOT EXISTS upload_delete_queue(path text PRIMARY KEY, status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running')), attempts integer NOT NULL DEFAULT 0, next_attempt_at bigint NOT NULL DEFAULT 0, locked_at bigint NOT NULL DEFAULT 0, last_error text NOT NULL DEFAULT '', created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_upload_delete_queue_due ON upload_delete_queue(status,next_attempt_at,created_at,path)"
    ]}
    ,{38, [
        %% Keep user associations outside the JSON blob so privacy erasure can
        %% delete queued webhook payloads without parsing arbitrary payload text.
        "ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS subject_user_id integer",
        "ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS actor_user_id integer",
        "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_subject_user ON webhook_deliveries(subject_user_id,id) WHERE subject_user_id IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_actor_user ON webhook_deliveries(actor_user_id,id) WHERE actor_user_id IS NOT NULL"
    ]}
    ,{39, [
        %% A privacy hard-delete must still identify the physical Scylla
        %% partitions if a prior ambiguous write left a row without a locator.
        %% Store only routing metadata; never duplicate message bodies here.
        "ALTER TABLE storage_outbox ADD COLUMN IF NOT EXISTS entity_scope text NOT NULL DEFAULT ''",
        "ALTER TABLE storage_outbox ADD COLUMN IF NOT EXISTS entity_scope_id bigint NOT NULL DEFAULT 0",
        "ALTER TABLE storage_outbox ADD COLUMN IF NOT EXISTS entity_created_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE storage_outbox DROP CONSTRAINT IF EXISTS storage_outbox_entity_scope_check",
        "ALTER TABLE storage_outbox ADD CONSTRAINT storage_outbox_entity_scope_check CHECK(entity_scope IN ('','channel','direct'))",
        "ALTER TABLE storage_outbox DROP CONSTRAINT IF EXISTS storage_outbox_entity_scope_id_check",
        "ALTER TABLE storage_outbox ADD CONSTRAINT storage_outbox_entity_scope_id_check CHECK(entity_scope_id >= 0)",
        "ALTER TABLE storage_outbox DROP CONSTRAINT IF EXISTS storage_outbox_entity_created_at_check",
        "ALTER TABLE storage_outbox ADD CONSTRAINT storage_outbox_entity_created_at_check CHECK(entity_created_at >= 0)"
    ]}

    ,{40, [
        %% Search never stores plaintext message terms. Tokens are keyed HMACs
        %% derived in Erlang and are useless without the instance search key.
        "CREATE TABLE IF NOT EXISTS message_search_tokens(message_id bigint NOT NULL REFERENCES messages(id) ON DELETE CASCADE, token text NOT NULL, PRIMARY KEY(message_id,token))",
        "CREATE INDEX IF NOT EXISTS idx_message_search_token ON message_search_tokens(token,message_id DESC)",
        "CREATE TABLE IF NOT EXISTS message_search_state(id smallint PRIMARY KEY CHECK(id=1), key_fingerprint text NOT NULL DEFAULT '', last_message_id bigint NOT NULL DEFAULT 0, complete boolean NOT NULL DEFAULT false, updated_at bigint NOT NULL DEFAULT 0)",
        "INSERT INTO message_search_state(id,key_fingerprint,last_message_id,complete,updated_at) VALUES(1,'',0,false,0) ON CONFLICT(id) DO NOTHING"
    ]}
    ,{41, [
        %% Bot commands are a durable, language-neutral queue. Command arguments
        %% are encrypted before storage; claim tokens are stored only as hashes.
        "CREATE TABLE IF NOT EXISTS bot_commands(id bigserial PRIMARY KEY,bot_id bigint NOT NULL REFERENCES server_bots(id) ON DELETE CASCADE,server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE,name text NOT NULL,description text NOT NULL DEFAULT '',options_json text NOT NULL DEFAULT '[]',enabled boolean NOT NULL DEFAULT true,created_at bigint NOT NULL,updated_at bigint NOT NULL,UNIQUE(server_id,name))",
        "CREATE INDEX IF NOT EXISTS idx_bot_commands_bot ON bot_commands(bot_id,id)",
        "CREATE TABLE IF NOT EXISTS bot_command_invocations(id bigserial PRIMARY KEY,command_id bigint NOT NULL REFERENCES bot_commands(id) ON DELETE CASCADE,bot_id bigint NOT NULL REFERENCES server_bots(id) ON DELETE CASCADE,server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE,channel_id integer NOT NULL REFERENCES channels(id) ON DELETE CASCADE,user_id integer REFERENCES users(id) ON DELETE SET NULL,request_message_id bigint REFERENCES messages(id) ON DELETE SET NULL,args_cipher text NOT NULL,status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','claimed','completed','failed')),claim_token_hash text NOT NULL DEFAULT '',lease_until bigint NOT NULL DEFAULT 0,attempts integer NOT NULL DEFAULT 0,response_message_id bigint,fail_reason text NOT NULL DEFAULT '',created_at bigint NOT NULL,updated_at bigint NOT NULL,completed_at bigint NOT NULL DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS idx_bot_command_invocations_claim ON bot_command_invocations(bot_id,status,lease_until,id)",
        "CREATE INDEX IF NOT EXISTS idx_bot_command_invocations_user ON bot_command_invocations(user_id,id DESC) WHERE user_id IS NOT NULL"
    ]}
    ,{42, [
        %% Host moderation changes account access only. It never grants the
        %% control plane access to messages or private attachment contents.
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderation_title text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderation_reason text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderation_severity text NOT NULL DEFAULT 'warning'",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderation_expires_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderated_by integer REFERENCES users(id) ON DELETE SET NULL",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderated_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_account_state_check",
        "ALTER TABLE users ADD CONSTRAINT users_account_state_check CHECK(account_state IN ('active','disabled','suspended','banned'))",
        "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_moderation_severity_check",
        "ALTER TABLE users ADD CONSTRAINT users_moderation_severity_check CHECK(moderation_severity IN ('info','warning','critical'))",
        "CREATE TABLE IF NOT EXISTS instance_account_actions(id bigserial PRIMARY KEY,user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,actor_user_id integer REFERENCES users(id) ON DELETE SET NULL,action text NOT NULL CHECK(action IN ('suspend','ban','restore')),title text NOT NULL DEFAULT '',reason text NOT NULL DEFAULT '',severity text NOT NULL DEFAULT 'warning',expires_at bigint NOT NULL DEFAULT 0,created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_instance_account_actions_user ON instance_account_actions(user_id,id DESC)"
    ]}
    ,{43, [
        %% Channel pins are deliberately separate from message rows so pin
        %% history can be changed without rewriting encrypted message bodies.
        "CREATE TABLE IF NOT EXISTS message_pins(channel_id integer NOT NULL REFERENCES channels(id) ON DELETE CASCADE,message_id bigint PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,pinned_by integer REFERENCES users(id) ON DELETE SET NULL,pinned_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_message_pins_channel ON message_pins(channel_id,pinned_at DESC,message_id DESC)"
    ]}
    ,{44, [
        %% Slowmode is channel configuration. Enforcement is serialized per
        %% user/channel at send time so concurrent API nodes cannot bypass it.
        "ALTER TABLE channels ADD COLUMN IF NOT EXISTS slowmode_seconds integer NOT NULL DEFAULT 0",
        "ALTER TABLE channels DROP CONSTRAINT IF EXISTS channels_slowmode_seconds_check",
        "ALTER TABLE channels ADD CONSTRAINT channels_slowmode_seconds_check CHECK(slowmode_seconds BETWEEN 0 AND 21600)"
    ]}
    ,{45, [
        %% Incoming channel webhooks have dedicated bot identities. Tokens are
        %% stored only as hashes; deleting a webhook disables its identity while
        %% preserving authorship of historical messages.
        "CREATE TABLE IF NOT EXISTS incoming_webhooks(id bigserial PRIMARY KEY,server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE,channel_id integer NOT NULL REFERENCES channels(id) ON DELETE CASCADE,bot_user_id integer NOT NULL UNIQUE REFERENCES users(id),name text NOT NULL,token_hash text NOT NULL UNIQUE,enabled boolean NOT NULL DEFAULT true,created_by integer REFERENCES users(id) ON DELETE SET NULL,created_at bigint NOT NULL,updated_at bigint NOT NULL,last_used_at bigint NOT NULL DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS idx_incoming_webhooks_server ON incoming_webhooks(server_id,id)",
        "CREATE INDEX IF NOT EXISTS idx_incoming_webhooks_channel ON incoming_webhooks(channel_id,id)"
    ]}
    ,{46, [
        %% User-owned developer applications are templates above server-scoped
        %% bot installations. Existing server_bots remain fully compatible.
        "CREATE TABLE IF NOT EXISTS developer_applications(id bigserial PRIMARY KEY,owner_user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,public_id text NOT NULL UNIQUE,name text NOT NULL,description text NOT NULL DEFAULT '',avatar_url text NOT NULL DEFAULT '',public boolean NOT NULL DEFAULT false,default_permissions bigint NOT NULL DEFAULT 0,interaction_url text NOT NULL DEFAULT '',interaction_secret text NOT NULL DEFAULT '',ai_enabled boolean NOT NULL DEFAULT false,ai_endpoint text NOT NULL DEFAULT '',ai_model text NOT NULL DEFAULT '',ai_api_key text NOT NULL DEFAULT '',ai_system_prompt text NOT NULL DEFAULT '',created_at bigint NOT NULL,updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_developer_applications_owner ON developer_applications(owner_user_id,id DESC)",
        "CREATE TABLE IF NOT EXISTS developer_app_installations(id bigserial PRIMARY KEY,app_id bigint NOT NULL REFERENCES developer_applications(id) ON DELETE CASCADE,server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE,server_bot_id bigint NOT NULL UNIQUE REFERENCES server_bots(id) ON DELETE CASCADE,role_id bigint REFERENCES server_roles(id) ON DELETE SET NULL,installed_by integer REFERENCES users(id) ON DELETE SET NULL,created_at bigint NOT NULL,UNIQUE(app_id,server_id))",
        "CREATE INDEX IF NOT EXISTS idx_developer_app_installations_app ON developer_app_installations(app_id,id)",
        "CREATE INDEX IF NOT EXISTS idx_developer_app_installations_server ON developer_app_installations(server_id,id)",
        "CREATE TABLE IF NOT EXISTS developer_app_commands(id bigserial PRIMARY KEY,app_id bigint NOT NULL REFERENCES developer_applications(id) ON DELETE CASCADE,name text NOT NULL,description text NOT NULL DEFAULT '',options_json text NOT NULL DEFAULT '[]',handler text NOT NULL DEFAULT 'queue' CHECK(handler IN ('queue','webhook','ai')),created_at bigint NOT NULL,updated_at bigint NOT NULL,UNIQUE(app_id,name))",
        "CREATE INDEX IF NOT EXISTS idx_developer_app_commands_app ON developer_app_commands(app_id,id)",
        "ALTER TABLE bot_commands ADD COLUMN IF NOT EXISTS developer_command_id bigint REFERENCES developer_app_commands(id) ON DELETE CASCADE",
        "ALTER TABLE bot_commands ADD COLUMN IF NOT EXISTS handler text NOT NULL DEFAULT 'queue'",
        "ALTER TABLE bot_commands DROP CONSTRAINT IF EXISTS bot_commands_handler_check",
        "ALTER TABLE bot_commands ADD CONSTRAINT bot_commands_handler_check CHECK(handler IN ('queue','webhook','ai'))",
        "CREATE INDEX IF NOT EXISTS idx_bot_commands_handler ON bot_commands(handler,bot_id,id)",
        "CREATE INDEX IF NOT EXISTS idx_bot_commands_developer_command ON bot_commands(developer_command_id) WHERE developer_command_id IS NOT NULL"
    ]}
    ,{47, [
        %% Server managers can narrow app-command usage by channel, role or
        %% member. Rules are evaluated at discovery and invocation time.
        "CREATE TABLE IF NOT EXISTS bot_command_permissions(command_id bigint NOT NULL REFERENCES bot_commands(id) ON DELETE CASCADE,subject_type text NOT NULL CHECK(subject_type IN ('channel','role','user')),subject_id bigint NOT NULL,allow boolean NOT NULL,created_at bigint NOT NULL,updated_at bigint NOT NULL,PRIMARY KEY(command_id,subject_type,subject_id))",
        "CREATE INDEX IF NOT EXISTS idx_bot_command_permissions_command ON bot_command_permissions(command_id,subject_type,subject_id)"
    ]}
    ,{48, [
        %% Internal webhook/AI workers claim across all installed bots. Keep the
        %% hot queue tiny even when completed invocation history becomes large;
        %% completed/failed rows deliberately do not occupy this partial index.
        "CREATE INDEX IF NOT EXISTS idx_bot_command_invocations_active ON bot_command_invocations(id,lease_until) WHERE status IN ('pending','claimed')"
    ]}
    ,{49, [
        %% Slowmode is evaluated on every channel message send. This partial
        %% index serves the exact channel+author live-message lookup without
        %% adding write amplification to deleted/direct/profile message rows.
        "CREATE INDEX IF NOT EXISTS idx_messages_channel_author_recent ON messages(scope_id,user_id,created_at DESC) WHERE scope='channel' AND deleted_at IS NULL"
    ]}
    ,{50, [
        "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check",
        "ALTER TABLE messages ADD CONSTRAINT messages_kind_check CHECK(kind IN ('text','missed_call','call_ended'))"
    ]}
    ,{51, [
        %% Provider-aware no-code AI assistants. Chat triggering is deliberately
        %% mention/reply-only so a bad prompt cannot make bots answer each other
        %% forever. Context is opt-in, bounded, and assembled only after the same
        %% channel authorization check used for command delivery.
        "ALTER TABLE developer_applications ADD COLUMN IF NOT EXISTS ai_provider text NOT NULL DEFAULT 'openai_compatible'",
        "ALTER TABLE developer_applications ADD COLUMN IF NOT EXISTS ai_temperature double precision NOT NULL DEFAULT 0.7",
        "ALTER TABLE developer_applications ADD COLUMN IF NOT EXISTS ai_max_output_tokens integer NOT NULL DEFAULT 1000",
        "ALTER TABLE developer_applications ADD COLUMN IF NOT EXISTS ai_include_history boolean NOT NULL DEFAULT false",
        "ALTER TABLE developer_applications ADD COLUMN IF NOT EXISTS ai_history_messages integer NOT NULL DEFAULT 8",
        "ALTER TABLE developer_applications ADD COLUMN IF NOT EXISTS ai_chat_enabled boolean NOT NULL DEFAULT false",
        "ALTER TABLE developer_applications ADD COLUMN IF NOT EXISTS ai_chat_trigger text NOT NULL DEFAULT 'mention_or_reply'",
        "ALTER TABLE developer_applications DROP CONSTRAINT IF EXISTS developer_applications_ai_provider_check",
        "ALTER TABLE developer_applications ADD CONSTRAINT developer_applications_ai_provider_check CHECK(ai_provider IN ('openai','openai_responses','openai_compatible','anthropic','google','openrouter','groq','mistral','ollama'))",
        "ALTER TABLE developer_applications DROP CONSTRAINT IF EXISTS developer_applications_ai_temperature_check",
        "ALTER TABLE developer_applications ADD CONSTRAINT developer_applications_ai_temperature_check CHECK(ai_temperature BETWEEN 0 AND 2)",
        "ALTER TABLE developer_applications DROP CONSTRAINT IF EXISTS developer_applications_ai_max_output_tokens_check",
        "ALTER TABLE developer_applications ADD CONSTRAINT developer_applications_ai_max_output_tokens_check CHECK(ai_max_output_tokens BETWEEN 64 AND 8192)",
        "ALTER TABLE developer_applications DROP CONSTRAINT IF EXISTS developer_applications_ai_history_messages_check",
        "ALTER TABLE developer_applications ADD CONSTRAINT developer_applications_ai_history_messages_check CHECK(ai_history_messages BETWEEN 0 AND 20)",
        "ALTER TABLE developer_applications DROP CONSTRAINT IF EXISTS developer_applications_ai_chat_trigger_check",
        "ALTER TABLE developer_applications ADD CONSTRAINT developer_applications_ai_chat_trigger_check CHECK(ai_chat_trigger IN ('mention','mention_or_reply'))",
        "CREATE INDEX IF NOT EXISTS idx_bot_command_invocations_developer_activity ON bot_command_invocations(command_id,id DESC)"
    ]}
    ,{52, [
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS email text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified boolean NOT NULL DEFAULT false",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at bigint NOT NULL DEFAULT 0",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_verified_email ON users (lower(email)) WHERE email <> '' AND email_verified = true",
        "CREATE TABLE IF NOT EXISTS account_tokens("
        "id bigserial PRIMARY KEY, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "purpose text NOT NULL, "
        "token_hash text NOT NULL, "
        "email text NOT NULL, "
        "expires_at bigint NOT NULL, "
        "used_at bigint, "
        "created_at bigint NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_account_tokens_hash ON account_tokens(token_hash)",
        "CREATE INDEX IF NOT EXISTS idx_account_tokens_user_purpose ON account_tokens(user_id, purpose, created_at DESC)",
        "ALTER TABLE account_tokens DROP CONSTRAINT IF EXISTS account_tokens_purpose_check",
        "ALTER TABLE account_tokens ADD CONSTRAINT account_tokens_purpose_check CHECK(purpose IN ('password_reset','email_verify'))"
    ]}
    ,{53, [
        %% Operators can disable accounts, revoke sessions, and maintain
        %% non-secret profile fields. The action log stays content-free.
        "ALTER TABLE instance_account_actions DROP CONSTRAINT IF EXISTS instance_account_actions_action_check",
        "ALTER TABLE instance_account_actions ADD CONSTRAINT instance_account_actions_action_check CHECK(action IN ('suspend','ban','restore','disable','revoke_sessions','clear_display_name','remove_email','resend_verification'))"
    ]}
].
