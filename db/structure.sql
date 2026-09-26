SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: bump_translation_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bump_translation_revision() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE translation_trees SET revision=revision+1,updated_at=NOW() WHERE id IN (SELECT DISTINCT translation_tree_id FROM changed_records);
  RETURN NULL;
END $$;


--
-- Name: guard_content_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_content_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_TABLE_NAME='translation_trees' THEN
    IF NEW.sheet_id<>OLD.sheet_id THEN RAISE EXCEPTION 'Moving trees across sheets is not supported' USING ERRCODE='23514'; END IF;
  ELSIF TG_TABLE_NAME='project_memberships' THEN
    IF NEW.project_id<>OLD.project_id THEN RAISE EXCEPTION 'Moving memberships across projects is not supported' USING ERRCODE='23514'; END IF;
  ELSE
    IF NEW.project_id IS NOT NULL AND NEW.project_id IS DISTINCT FROM OLD.project_id THEN RAISE EXCEPTION 'Moving languages across projects is not supported' USING ERRCODE='23514'; END IF;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: guard_last_global_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_last_global_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.role=2 AND OLD.banned_at IS NULL AND OLD.email_verified_at IS NOT NULL AND NOT EXISTS(SELECT 1 FROM users WHERE role=2 AND banned_at IS NULL AND email_verified_at IS NOT NULL) THEN
    RAISE EXCEPTION 'At least one active application owner must remain' USING ERRCODE='23514';
  END IF;
  RETURN NULL;
END $$;


--
-- Name: guard_last_project_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_last_project_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.role='owner' AND EXISTS(SELECT 1 FROM projects WHERE id=OLD.project_id) AND NOT EXISTS(SELECT 1 FROM project_memberships WHERE project_id=OLD.project_id AND role='owner') THEN
    RAISE EXCEPTION 'At least one project owner must remain' USING ERRCODE='23514';
  END IF;
  RETURN NULL;
END $$;


--
-- Name: guard_project_membership(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_project_membership() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM 1 FROM projects WHERE id=COALESCE(NEW.project_id,OLD.project_id) FOR UPDATE;
  IF TG_OP='INSERT' OR (TG_OP='UPDATE' AND NEW.project_id<>OLD.project_id) THEN
    IF (SELECT count(*) FROM project_memberships WHERE project_id=NEW.project_id)>=200 THEN RAISE EXCEPTION 'A project can have at most 200 members' USING ERRCODE='23514'; END IF;
  END IF;
  RETURN COALESCE(NEW,OLD);
END $$;


--
-- Name: guard_recording(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_recording() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE owner_sheet sheets; parent_record recordings; key_name text; lang bigint;
BEGIN
  -- Serialize structural checks within one tree, including raw SQL writes.
  PERFORM 1 FROM translation_trees WHERE id=NEW.translation_tree_id FOR UPDATE;
  SELECT s.* INTO STRICT owner_sheet FROM sheets s JOIN translation_trees t ON t.sheet_id=s.id WHERE t.id=NEW.translation_tree_id;
  IF TG_OP='UPDATE' AND NEW.translation_tree_id<>OLD.translation_tree_id THEN RAISE EXCEPTION 'Moving across trees is not supported' USING ERRCODE='23514'; END IF;
  IF NEW.parent_id IS NOT NULL THEN
    SELECT * INTO STRICT parent_record FROM recordings WHERE id=NEW.parent_id;
    IF parent_record.translation_tree_id<>NEW.translation_tree_id OR parent_record.recordable_type<>'TranslationKey' THEN RAISE EXCEPTION 'Invalid parent' USING ERRCODE='23514'; END IF;
    IF NEW.deleted_at IS NULL AND parent_record.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Parent is deleted' USING ERRCODE='23514'; END IF;
    IF EXISTS(WITH RECURSIVE ancestors AS (
      SELECT id,parent_id FROM recordings WHERE id=NEW.parent_id
      UNION SELECT r.id,r.parent_id FROM recordings r JOIN ancestors a ON r.id=a.parent_id
    ) SELECT 1 FROM ancestors WHERE id=NEW.id) THEN RAISE EXCEPTION 'Tree cycle' USING ERRCODE='23514'; END IF;
  ELSIF NEW.recordable_type<>'TranslationKey' THEN RAISE EXCEPTION 'A translation needs a key' USING ERRCODE='23514'; END IF;
  IF TG_OP='UPDATE' AND NEW.recordable_type<>OLD.recordable_type THEN RAISE EXCEPTION 'Recording type cannot change' USING ERRCODE='23514'; END IF;
  IF NEW.recordable_type='TranslationKey' THEN
    SELECT name INTO STRICT key_name FROM translation_keys WHERE id=NEW.recordable_id;
    IF NEW.deleted_at IS NULL AND EXISTS(SELECT 1 FROM recordings r JOIN translation_keys k ON k.id=r.recordable_id
      WHERE r.translation_tree_id=NEW.translation_tree_id AND r.parent_id IS NOT DISTINCT FROM NEW.parent_id
      AND r.recordable_type='TranslationKey' AND r.deleted_at IS NULL AND r.id<>NEW.id
      AND CASE WHEN owner_sheet.case_sensitive_keys THEN k.name=key_name ELSE lower(k.name)=lower(key_name) END)
    THEN RAISE EXCEPTION 'A key with this name already exists under this parent' USING ERRCODE='23514'; END IF;
  ELSE
    SELECT language_id INTO STRICT lang FROM text_translations WHERE id=NEW.recordable_id;
    IF NOT EXISTS(SELECT 1 FROM languages WHERE id=lang AND project_id=owner_sheet.project_id) THEN RAISE EXCEPTION 'Language belongs to another project' USING ERRCODE='23514'; END IF;
    IF NEW.deleted_at IS NULL AND EXISTS(SELECT 1 FROM recordings r JOIN text_translations v ON v.id=r.recordable_id
      WHERE r.parent_id=NEW.parent_id AND r.recordable_type='TextTranslation' AND r.deleted_at IS NULL AND r.id<>NEW.id AND v.language_id=lang)
    THEN RAISE EXCEPTION 'This key already has a translation in this language' USING ERRCODE='23514'; END IF;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: guard_recording_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_recording_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.recordable_type='TranslationKey' AND NOT EXISTS(SELECT 1 FROM translation_keys WHERE id=NEW.recordable_id) THEN
    RAISE EXCEPTION 'History key payload does not exist' USING ERRCODE='23503';
  ELSIF NEW.recordable_type='TextTranslation' AND NOT EXISTS(SELECT 1 FROM text_translations WHERE id=NEW.recordable_id) THEN
    RAISE EXCEPTION 'History translation payload does not exist' USING ERRCODE='23503';
  ELSIF NEW.recordable_type NOT IN ('TranslationKey','TextTranslation') THEN
    RAISE EXCEPTION 'Unsupported history payload type' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;


--
-- Name: guard_recording_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_recording_identity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.translation_tree_id<>OLD.translation_tree_id OR NEW.parent_id IS DISTINCT FROM OLD.parent_id THEN
    RAISE EXCEPTION 'Moving recordings is not supported' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;


--
-- Name: guard_retained_language(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_retained_language() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.project_id IS NULL AND EXISTS(SELECT 1 FROM projects WHERE id=OLD.project_id) THEN RAISE EXCEPTION 'A language can only be archived when its project is deleted' USING ERRCODE='23514'; END IF;
  RETURN NULL;
END $$;


--
-- Name: guard_sheet_delimiter(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_sheet_delimiter() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE separator text;
BEGIN
  IF TG_TABLE_NAME='sheets' THEN
    IF NEW.delimiter IS DISTINCT FROM OLD.delimiter AND EXISTS(
      SELECT 1 FROM recordings r JOIN translation_trees t ON t.id=r.translation_tree_id JOIN translation_keys k ON k.id=r.recordable_id
      WHERE t.sheet_id=NEW.id AND r.recordable_type='TranslationKey' AND r.deleted_at IS NULL AND position(NEW.delimiter in k.name)>0
    ) THEN RAISE EXCEPTION 'Cannot change delimiter: existing keys contain this character. Rename them first.' USING ERRCODE='23514'; END IF;
  ELSIF NEW.recordable_type='TranslationKey' AND NEW.deleted_at IS NULL THEN
    SELECT s.delimiter INTO separator FROM sheets s JOIN translation_trees t ON t.sheet_id=s.id WHERE t.id=NEW.translation_tree_id;
    IF EXISTS(SELECT 1 FROM translation_keys WHERE id=NEW.recordable_id AND position(separator in name)>0) THEN
      RAISE EXCEPTION 'A key name cannot contain the sheet delimiter' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: guard_sheet_languages(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_sheet_languages() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE project bigint;
BEGIN
  IF TG_TABLE_NAME='sheet_languages' THEN SELECT project_id INTO project FROM sheets WHERE id=NEW.sheet_id;
  ELSE SELECT project_id INTO project FROM project_memberships WHERE id=NEW.project_membership_id; END IF;
  IF NOT EXISTS(SELECT 1 FROM languages WHERE id=NEW.language_id AND project_id=project) THEN RAISE EXCEPTION 'Language belongs to another project' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END $$;


--
-- Name: guard_sheet_structure(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_sheet_structure() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM 1 FROM projects WHERE id=NEW.project_id FOR UPDATE;
  IF TG_OP='INSERT' AND (SELECT count(*) FROM sheets WHERE project_id=NEW.project_id)>=90 THEN RAISE EXCEPTION 'A project can contain at most 90 sheets' USING ERRCODE='23514'; END IF;
  IF NEW.default_language_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM languages WHERE id=NEW.default_language_id AND project_id=NEW.project_id) THEN RAISE EXCEPTION 'Default language belongs to another project' USING ERRCODE='23514'; END IF;
  IF TG_OP='UPDATE' THEN
    IF NEW.project_id<>OLD.project_id THEN RAISE EXCEPTION 'Moving sheets across projects is not supported' USING ERRCODE='23514'; END IF;
    PERFORM 1 FROM translation_trees WHERE sheet_id=NEW.id FOR UPDATE;
    IF NOT NEW.case_sensitive_keys AND EXISTS(SELECT 1 FROM recordings r JOIN translation_keys k ON k.id=r.recordable_id JOIN translation_trees t ON t.id=r.translation_tree_id
      WHERE t.sheet_id=NEW.id AND r.recordable_type='TranslationKey' AND r.deleted_at IS NULL
      GROUP BY r.translation_tree_id,r.parent_id,lower(k.name) HAVING count(*)>1)
    THEN RAISE EXCEPTION 'Resolve case-conflicting keys before disabling case sensitivity' USING ERRCODE='23514'; END IF;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: immutable_translation_payload(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.immutable_translation_payload() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF current_setting('app.purge_language', true)='on' THEN RETURN OLD; END IF;
  RAISE EXCEPTION 'Translation payloads are immutable' USING ERRCODE='23514';
END $$;


--
-- Name: serialize_owner_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.serialize_owner_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Only owner mutations contend; ordinary profile edits do not take this lock.
  IF OLD.role=2 OR (TG_OP='UPDATE' AND NEW.role=2) THEN PERFORM pg_advisory_xact_lock(7142001); END IF;
  RETURN COALESCE(NEW,OLD);
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: auth_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_identities (
    id bigint NOT NULL,
    user_id uuid NOT NULL,
    provider character varying NOT NULL,
    provider_uid character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    display_name character varying
);


--
-- Name: auth_identities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_identities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_identities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_identities_id_seq OWNED BY public.auth_identities.id;


--
-- Name: auth_rate_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_rate_limits (
    key character varying NOT NULL,
    count integer DEFAULT 0 NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL
);


--
-- Name: email_challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_challenges (
    id bigint NOT NULL,
    email character varying NOT NULL,
    purpose character varying NOT NULL,
    digest character varying NOT NULL,
    password_digest character varying,
    name character varying,
    expires_at timestamp(6) without time zone NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    consumed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    digest_token character varying
);


--
-- Name: email_challenges_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_challenges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_challenges_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_challenges_id_seq OWNED BY public.email_challenges.id;


--
-- Name: export_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.export_requests (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    user_id uuid,
    owner_key character varying NOT NULL,
    options jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'queued'::character varying NOT NULL,
    progress integer DEFAULT 0 NOT NULL,
    filename character varying,
    error text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    storage_key character varying
);


--
-- Name: export_requests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.export_requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: export_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.export_requests_id_seq OWNED BY public.export_requests.id;


--
-- Name: identifier_sets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identifier_sets (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    name character varying NOT NULL,
    description text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: identifier_sets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.identifier_sets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: identifier_sets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.identifier_sets_id_seq OWNED BY public.identifier_sets.id;


--
-- Name: invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitations (
    id bigint NOT NULL,
    email character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: invitations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.invitations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: invitations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.invitations_id_seq OWNED BY public.invitations.id;


--
-- Name: language_identifiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.language_identifiers (
    id bigint NOT NULL,
    identifier_set_id bigint NOT NULL,
    language_id bigint NOT NULL,
    identifier character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: language_identifiers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.language_identifiers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: language_identifiers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.language_identifiers_id_seq OWNED BY public.language_identifiers.id;


--
-- Name: languages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.languages (
    id bigint NOT NULL,
    project_id bigint,
    name character varying NOT NULL,
    identifier character varying NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    CONSTRAINT language_identity CHECK (((length((name)::text) > 0) AND ((identifier)::text ~ '^[a-z0-9]+([-_][a-z0-9]+)*$'::text))),
    CONSTRAINT language_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'archived'::character varying, 'pending_deletion'::character varying])::text[])))
);


--
-- Name: languages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.languages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: languages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.languages_id_seq OWNED BY public.languages.id;


--
-- Name: membership_languages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.membership_languages (
    id bigint NOT NULL,
    project_membership_id bigint NOT NULL,
    language_id bigint NOT NULL
);


--
-- Name: membership_languages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.membership_languages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: membership_languages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.membership_languages_id_seq OWNED BY public.membership_languages.id;


--
-- Name: numeric_id_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.numeric_id_mappings (
    table_name character varying NOT NULL,
    old_id uuid NOT NULL,
    new_id bigint NOT NULL
);


--
-- Name: project_invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_invites (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    email character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    role character varying DEFAULT 'viewer'::character varying NOT NULL,
    invited_by_id uuid,
    CONSTRAINT project_invite_role CHECK (((role)::text = ANY ((ARRAY['viewer'::character varying, 'translator'::character varying])::text[])))
);


--
-- Name: project_invites_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.project_invites_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_invites_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.project_invites_id_seq OWNED BY public.project_invites.id;


--
-- Name: project_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_memberships (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    user_id uuid NOT NULL,
    role character varying DEFAULT 'viewer'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT project_membership_role CHECK (((role)::text = ANY ((ARRAY['viewer'::character varying, 'translator'::character varying, 'admin'::character varying, 'owner'::character varying])::text[])))
);


--
-- Name: project_memberships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.project_memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_memberships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.project_memberships_id_seq OWNED BY public.project_memberships.id;


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id bigint NOT NULL,
    name character varying NOT NULL,
    visibility character varying DEFAULT 'private'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    slug character varying NOT NULL,
    advanced_languages boolean DEFAULT false NOT NULL,
    CONSTRAINT projects_slug_format CHECK ((((slug)::text ~ '^[a-z0-9]+([-_][a-z0-9]+)*$'::text) AND (length((slug)::text) <= 100) AND ((slug)::text <> ALL ((ARRAY['new'::character varying, 'edit'::character varying])::text[])))),
    CONSTRAINT projects_visibility CHECK (((visibility)::text = ANY ((ARRAY['public'::character varying, 'private'::character varying])::text[])))
);


--
-- Name: projects_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.projects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: projects_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.projects_id_seq OWNED BY public.projects.id;


--
-- Name: recording_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recording_events (
    id bigint NOT NULL,
    recording_id bigint NOT NULL,
    actor_id uuid,
    action character varying NOT NULL,
    recordable_type character varying NOT NULL,
    recordable_id bigint NOT NULL,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    change_id bigint NOT NULL,
    change_type character varying DEFAULT 'manual'::character varying NOT NULL,
    CONSTRAINT recording_event_action CHECK (((action)::text = ANY ((ARRAY['created'::character varying, 'updated'::character varying, 'deleted'::character varying])::text[]))),
    CONSTRAINT recording_event_change_type CHECK (((change_type)::text = ANY ((ARRAY['manual'::character varying, 'revert'::character varying, 'import'::character varying])::text[]))),
    CONSTRAINT recording_event_deletion CHECK ((((action)::text = 'deleted'::text) = (deleted_at IS NOT NULL)))
);


--
-- Name: recording_event_change_ids; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recording_event_change_ids
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recording_event_change_ids; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recording_event_change_ids OWNED BY public.recording_events.change_id;


--
-- Name: recording_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recording_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recording_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recording_events_id_seq OWNED BY public.recording_events.id;


--
-- Name: recordings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recordings (
    id bigint NOT NULL,
    translation_tree_id bigint NOT NULL,
    parent_id bigint,
    recordable_type character varying NOT NULL,
    recordable_id bigint NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT recording_type_parent CHECK ((((recordable_type)::text = ANY (ARRAY[('TranslationKey'::character varying)::text, ('TextTranslation'::character varying)::text])) AND ((parent_id IS NULL) OR (parent_id <> id))))
);


--
-- Name: recordings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recordings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recordings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recordings_id_seq OWNED BY public.recordings.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sheet_languages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sheet_languages (
    id bigint NOT NULL,
    sheet_id bigint NOT NULL,
    language_id bigint NOT NULL,
    enabled boolean DEFAULT true NOT NULL
);


--
-- Name: sheet_languages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sheet_languages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sheet_languages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sheet_languages_id_seq OWNED BY public.sheet_languages.id;


--
-- Name: sheets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sheets (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    name character varying NOT NULL,
    visibility character varying DEFAULT 'private'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    slug character varying NOT NULL,
    default_language_id bigint,
    case_sensitive_keys boolean DEFAULT false NOT NULL,
    allow_parent_translations boolean DEFAULT false NOT NULL,
    pluralization_enabled boolean DEFAULT true NOT NULL,
    plural_categories character varying[] DEFAULT '{zero,one,two,few,many,other}'::character varying[] NOT NULL,
    missing_value_behavior character varying DEFAULT 'omit'::character varying NOT NULL,
    delimiter character varying DEFAULT '.'::character varying NOT NULL,
    description text,
    image_data bytea,
    wildcard_format character varying DEFAULT ''::character varying NOT NULL,
    CONSTRAINT sheet_delimiter_character CHECK (((char_length((delimiter)::text) >= 1) AND (char_length((delimiter)::text) <= 3))),
    CONSTRAINT sheet_missing_values CHECK (((missing_value_behavior)::text = ANY ((ARRAY['omit'::character varying, 'empty'::character varying, 'fallback'::character varying])::text[]))),
    CONSTRAINT sheets_slug_format CHECK ((((slug)::text ~ '^[a-z0-9]+([-_][a-z0-9]+)*$'::text) AND (length((slug)::text) <= 100) AND ((slug)::text <> ALL ((ARRAY['new'::character varying, 'edit'::character varying])::text[])))),
    CONSTRAINT sheets_visibility CHECK (((visibility)::text = ANY ((ARRAY['public'::character varying, 'private'::character varying])::text[])))
);


--
-- Name: sheets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sheets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sheets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sheets_id_seq OWNED BY public.sheets.id;


--
-- Name: solid_queue_blocked_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_blocked_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    concurrency_key character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_blocked_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_blocked_executions_id_seq OWNED BY public.solid_queue_blocked_executions.id;


--
-- Name: solid_queue_claimed_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_claimed_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    process_id bigint,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_claimed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_claimed_executions_id_seq OWNED BY public.solid_queue_claimed_executions.id;


--
-- Name: solid_queue_failed_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_failed_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    error text,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_failed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_failed_executions_id_seq OWNED BY public.solid_queue_failed_executions.id;


--
-- Name: solid_queue_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_jobs (
    id bigint NOT NULL,
    queue_name character varying NOT NULL,
    class_name character varying NOT NULL,
    arguments text,
    priority integer DEFAULT 0 NOT NULL,
    active_job_id character varying,
    scheduled_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    concurrency_key character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_jobs_id_seq OWNED BY public.solid_queue_jobs.id;


--
-- Name: solid_queue_pauses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_pauses (
    id bigint NOT NULL,
    queue_name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_pauses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_pauses_id_seq OWNED BY public.solid_queue_pauses.id;


--
-- Name: solid_queue_processes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_processes (
    id bigint NOT NULL,
    kind character varying NOT NULL,
    last_heartbeat_at timestamp(6) without time zone NOT NULL,
    supervisor_id bigint,
    pid integer NOT NULL,
    hostname character varying,
    metadata text,
    created_at timestamp(6) without time zone NOT NULL,
    name character varying NOT NULL
);


--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_processes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_processes_id_seq OWNED BY public.solid_queue_processes.id;


--
-- Name: solid_queue_ready_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_ready_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_ready_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_ready_executions_id_seq OWNED BY public.solid_queue_ready_executions.id;


--
-- Name: solid_queue_recurring_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_recurring_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    task_key character varying NOT NULL,
    run_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_recurring_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_recurring_executions_id_seq OWNED BY public.solid_queue_recurring_executions.id;


--
-- Name: solid_queue_recurring_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_recurring_tasks (
    id bigint NOT NULL,
    key character varying NOT NULL,
    schedule character varying NOT NULL,
    command character varying(2048),
    class_name character varying,
    arguments text,
    queue_name character varying,
    priority integer DEFAULT 0,
    static boolean DEFAULT true NOT NULL,
    description text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_recurring_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_recurring_tasks_id_seq OWNED BY public.solid_queue_recurring_tasks.id;


--
-- Name: solid_queue_scheduled_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_scheduled_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    scheduled_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_scheduled_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_scheduled_executions_id_seq OWNED BY public.solid_queue_scheduled_executions.id;


--
-- Name: solid_queue_semaphores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_semaphores (
    id bigint NOT NULL,
    key character varying NOT NULL,
    value integer DEFAULT 1 NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_semaphores_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_semaphores_id_seq OWNED BY public.solid_queue_semaphores.id;


--
-- Name: text_translations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.text_translations (
    id bigint NOT NULL,
    language_id bigint NOT NULL,
    text text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT translation_nonempty CHECK ((length(text) > 0))
);


--
-- Name: text_translations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.text_translations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: text_translations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.text_translations_id_seq OWNED BY public.text_translations.id;


--
-- Name: translation_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_keys (
    id bigint NOT NULL,
    name character varying NOT NULL,
    pluralized boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    CONSTRAINT key_name_length CHECK (((length((name)::text) >= 1) AND (length((name)::text) <= 200)))
);


--
-- Name: translation_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.translation_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: translation_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.translation_keys_id_seq OWNED BY public.translation_keys.id;


--
-- Name: translation_trees; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translation_trees (
    id bigint NOT NULL,
    sheet_id bigint NOT NULL,
    name character varying DEFAULT 'main'::character varying NOT NULL,
    revision bigint DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: translation_trees_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.translation_trees_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: translation_trees_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.translation_trees_id_seq OWNED BY public.translation_trees.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    email character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    name character varying,
    remember_created_at timestamp(6) without time zone,
    reset_password_sent_at timestamp(6) without time zone,
    reset_password_token character varying,
    role integer DEFAULT 0 NOT NULL,
    theme_preference character varying DEFAULT 'system'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email_verified_at timestamp(6) without time zone,
    banned_at timestamp(6) without time zone,
    access_granted_at timestamp(6) without time zone,
    profile_photo bytea,
    profile_photo_customized boolean DEFAULT false NOT NULL
);


--
-- Name: auth_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_identities ALTER COLUMN id SET DEFAULT nextval('public.auth_identities_id_seq'::regclass);


--
-- Name: email_challenges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_challenges ALTER COLUMN id SET DEFAULT nextval('public.email_challenges_id_seq'::regclass);


--
-- Name: export_requests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.export_requests ALTER COLUMN id SET DEFAULT nextval('public.export_requests_id_seq'::regclass);


--
-- Name: identifier_sets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identifier_sets ALTER COLUMN id SET DEFAULT nextval('public.identifier_sets_id_seq'::regclass);


--
-- Name: invitations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations ALTER COLUMN id SET DEFAULT nextval('public.invitations_id_seq'::regclass);


--
-- Name: language_identifiers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.language_identifiers ALTER COLUMN id SET DEFAULT nextval('public.language_identifiers_id_seq'::regclass);


--
-- Name: languages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.languages ALTER COLUMN id SET DEFAULT nextval('public.languages_id_seq'::regclass);


--
-- Name: membership_languages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_languages ALTER COLUMN id SET DEFAULT nextval('public.membership_languages_id_seq'::regclass);


--
-- Name: project_invites id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_invites ALTER COLUMN id SET DEFAULT nextval('public.project_invites_id_seq'::regclass);


--
-- Name: project_memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships ALTER COLUMN id SET DEFAULT nextval('public.project_memberships_id_seq'::regclass);


--
-- Name: projects id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects ALTER COLUMN id SET DEFAULT nextval('public.projects_id_seq'::regclass);


--
-- Name: recording_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_events ALTER COLUMN id SET DEFAULT nextval('public.recording_events_id_seq'::regclass);


--
-- Name: recording_events change_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_events ALTER COLUMN change_id SET DEFAULT nextval('public.recording_event_change_ids'::regclass);


--
-- Name: recordings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recordings ALTER COLUMN id SET DEFAULT nextval('public.recordings_id_seq'::regclass);


--
-- Name: sheet_languages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sheet_languages ALTER COLUMN id SET DEFAULT nextval('public.sheet_languages_id_seq'::regclass);


--
-- Name: sheets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sheets ALTER COLUMN id SET DEFAULT nextval('public.sheets_id_seq'::regclass);


--
-- Name: solid_queue_blocked_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_blocked_executions_id_seq'::regclass);


--
-- Name: solid_queue_claimed_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_claimed_executions_id_seq'::regclass);


--
-- Name: solid_queue_failed_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_failed_executions_id_seq'::regclass);


--
-- Name: solid_queue_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_jobs ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_jobs_id_seq'::regclass);


--
-- Name: solid_queue_pauses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_pauses ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_pauses_id_seq'::regclass);


--
-- Name: solid_queue_processes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_processes ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_processes_id_seq'::regclass);


--
-- Name: solid_queue_ready_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_ready_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_tasks_id_seq'::regclass);


--
-- Name: solid_queue_scheduled_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_scheduled_executions_id_seq'::regclass);


--
-- Name: solid_queue_semaphores id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_semaphores ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_semaphores_id_seq'::regclass);


--
-- Name: text_translations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.text_translations ALTER COLUMN id SET DEFAULT nextval('public.text_translations_id_seq'::regclass);


--
-- Name: translation_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_keys ALTER COLUMN id SET DEFAULT nextval('public.translation_keys_id_seq'::regclass);


--
-- Name: translation_trees id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_trees ALTER COLUMN id SET DEFAULT nextval('public.translation_trees_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: auth_identities auth_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_identities
    ADD CONSTRAINT auth_identities_pkey PRIMARY KEY (id);


--
-- Name: auth_rate_limits auth_rate_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_rate_limits
    ADD CONSTRAINT auth_rate_limits_pkey PRIMARY KEY (key);


--
-- Name: email_challenges email_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_challenges
    ADD CONSTRAINT email_challenges_pkey PRIMARY KEY (id);


--
-- Name: export_requests export_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.export_requests
    ADD CONSTRAINT export_requests_pkey PRIMARY KEY (id);


--
-- Name: identifier_sets identifier_sets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identifier_sets
    ADD CONSTRAINT identifier_sets_pkey PRIMARY KEY (id);


--
-- Name: invitations invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT invitations_pkey PRIMARY KEY (id);


--
-- Name: language_identifiers language_identifiers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.language_identifiers
    ADD CONSTRAINT language_identifiers_pkey PRIMARY KEY (id);


--
-- Name: languages languages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.languages
    ADD CONSTRAINT languages_pkey PRIMARY KEY (id);


--
-- Name: membership_languages membership_languages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_languages
    ADD CONSTRAINT membership_languages_pkey PRIMARY KEY (id);


--
-- Name: project_invites project_invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_invites
    ADD CONSTRAINT project_invites_pkey PRIMARY KEY (id);


--
-- Name: project_memberships project_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships
    ADD CONSTRAINT project_memberships_pkey PRIMARY KEY (id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: recording_events recording_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_events
    ADD CONSTRAINT recording_events_pkey PRIMARY KEY (id);


--
-- Name: recordings recordings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recordings
    ADD CONSTRAINT recordings_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sheet_languages sheet_languages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sheet_languages
    ADD CONSTRAINT sheet_languages_pkey PRIMARY KEY (id);


--
-- Name: sheets sheets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sheets
    ADD CONSTRAINT sheets_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_blocked_executions solid_queue_blocked_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT solid_queue_blocked_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_claimed_executions solid_queue_claimed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT solid_queue_claimed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_failed_executions solid_queue_failed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT solid_queue_failed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_jobs solid_queue_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_jobs
    ADD CONSTRAINT solid_queue_jobs_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_pauses solid_queue_pauses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_pauses
    ADD CONSTRAINT solid_queue_pauses_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_processes solid_queue_processes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_processes
    ADD CONSTRAINT solid_queue_processes_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_ready_executions solid_queue_ready_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT solid_queue_ready_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_executions solid_queue_recurring_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT solid_queue_recurring_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_tasks solid_queue_recurring_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks
    ADD CONSTRAINT solid_queue_recurring_tasks_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_scheduled_executions solid_queue_scheduled_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT solid_queue_scheduled_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_semaphores solid_queue_semaphores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_semaphores
    ADD CONSTRAINT solid_queue_semaphores_pkey PRIMARY KEY (id);


--
-- Name: text_translations text_translations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.text_translations
    ADD CONSTRAINT text_translations_pkey PRIMARY KEY (id);


--
-- Name: translation_keys translation_key_no_whitespace; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.translation_keys
    ADD CONSTRAINT translation_key_no_whitespace CHECK (((name)::text !~ '[[:space:]]'::text)) NOT VALID;


--
-- Name: translation_keys translation_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_keys
    ADD CONSTRAINT translation_keys_pkey PRIMARY KEY (id);


--
-- Name: translation_trees translation_trees_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_trees
    ADD CONSTRAINT translation_trees_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: active_tree_children; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX active_tree_children ON public.recordings USING btree (translation_tree_id, parent_id) WHERE (deleted_at IS NULL);


--
-- Name: index_auth_identities_on_provider_and_provider_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_auth_identities_on_provider_and_provider_uid ON public.auth_identities USING btree (provider, provider_uid);


--
-- Name: index_auth_identities_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_auth_identities_on_user_id ON public.auth_identities USING btree (user_id);


--
-- Name: index_auth_identities_on_user_id_and_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_auth_identities_on_user_id_and_provider ON public.auth_identities USING btree (user_id, provider);


--
-- Name: index_auth_rate_limits_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_auth_rate_limits_on_expires_at ON public.auth_rate_limits USING btree (expires_at);


--
-- Name: index_email_challenges_on_email_and_purpose; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_challenges_on_email_and_purpose ON public.email_challenges USING btree (email, purpose);


--
-- Name: index_email_challenges_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_email_challenges_on_expires_at ON public.email_challenges USING btree (expires_at);


--
-- Name: index_export_requests_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_export_requests_on_project_id ON public.export_requests USING btree (project_id);


--
-- Name: index_export_requests_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_export_requests_on_user_id ON public.export_requests USING btree (user_id);


--
-- Name: index_identifier_sets_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_identifier_sets_on_project_id ON public.identifier_sets USING btree (project_id);


--
-- Name: index_identifier_sets_on_project_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_identifier_sets_on_project_id_and_name ON public.identifier_sets USING btree (project_id, name);


--
-- Name: index_invitations_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_invitations_on_email ON public.invitations USING btree (email);


--
-- Name: index_language_identifiers_on_identifier_set_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_language_identifiers_on_identifier_set_id ON public.language_identifiers USING btree (identifier_set_id);


--
-- Name: index_language_identifiers_on_language_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_language_identifiers_on_language_id ON public.language_identifiers USING btree (language_id);


--
-- Name: index_languages_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_languages_on_project_id ON public.languages USING btree (project_id);


--
-- Name: index_languages_on_project_id_and_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_languages_on_project_id_and_identifier ON public.languages USING btree (project_id, identifier);


--
-- Name: index_languages_on_project_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_languages_on_project_id_and_status ON public.languages USING btree (project_id, status);


--
-- Name: index_membership_languages_on_language_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_membership_languages_on_language_id ON public.membership_languages USING btree (language_id);


--
-- Name: index_membership_languages_on_project_membership_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_membership_languages_on_project_membership_id ON public.membership_languages USING btree (project_membership_id);


--
-- Name: index_numeric_id_mappings_on_table_name_and_new_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_numeric_id_mappings_on_table_name_and_new_id ON public.numeric_id_mappings USING btree (table_name, new_id);


--
-- Name: index_numeric_id_mappings_on_table_name_and_old_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_numeric_id_mappings_on_table_name_and_old_id ON public.numeric_id_mappings USING btree (table_name, old_id);


--
-- Name: index_project_invites_on_invited_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_invites_on_invited_by_id ON public.project_invites USING btree (invited_by_id);


--
-- Name: index_project_invites_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_invites_on_project_id ON public.project_invites USING btree (project_id);


--
-- Name: index_project_invites_on_project_id_and_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_project_invites_on_project_id_and_email ON public.project_invites USING btree (project_id, email);


--
-- Name: index_project_memberships_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_memberships_on_project_id ON public.project_memberships USING btree (project_id);


--
-- Name: index_project_memberships_on_project_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_project_memberships_on_project_id_and_user_id ON public.project_memberships USING btree (project_id, user_id);


--
-- Name: index_project_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_project_memberships_on_user_id ON public.project_memberships USING btree (user_id);


--
-- Name: index_projects_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_projects_on_slug ON public.projects USING btree (slug);


--
-- Name: index_recording_events_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_events_on_actor_id ON public.recording_events USING btree (actor_id);


--
-- Name: index_recording_events_on_change_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_events_on_change_id ON public.recording_events USING btree (change_id);


--
-- Name: index_recording_events_on_recordable_type_and_recordable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_events_on_recordable_type_and_recordable_id ON public.recording_events USING btree (recordable_type, recordable_id);


--
-- Name: index_recording_events_on_recording_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_events_on_recording_id ON public.recording_events USING btree (recording_id);


--
-- Name: index_recording_events_on_recording_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recording_events_on_recording_id_and_id ON public.recording_events USING btree (recording_id, id);


--
-- Name: index_recordings_on_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recordings_on_parent_id ON public.recordings USING btree (parent_id);


--
-- Name: index_recordings_on_recordable_type_and_recordable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recordings_on_recordable_type_and_recordable_id ON public.recordings USING btree (recordable_type, recordable_id);


--
-- Name: index_recordings_on_translation_tree_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recordings_on_translation_tree_id ON public.recordings USING btree (translation_tree_id);


--
-- Name: index_sheet_languages_on_language_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sheet_languages_on_language_id ON public.sheet_languages USING btree (language_id);


--
-- Name: index_sheet_languages_on_sheet_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sheet_languages_on_sheet_id ON public.sheet_languages USING btree (sheet_id);


--
-- Name: index_sheet_languages_on_sheet_id_and_language_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sheet_languages_on_sheet_id_and_language_id ON public.sheet_languages USING btree (sheet_id, language_id);


--
-- Name: index_sheets_on_default_language_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sheets_on_default_language_id ON public.sheets USING btree (default_language_id);


--
-- Name: index_sheets_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sheets_on_project_id ON public.sheets USING btree (project_id);


--
-- Name: index_sheets_on_project_id_and_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sheets_on_project_id_and_slug ON public.sheets USING btree (project_id, slug);


--
-- Name: index_solid_queue_blocked_executions_for_maintenance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_blocked_executions_for_maintenance ON public.solid_queue_blocked_executions USING btree (expires_at, concurrency_key);


--
-- Name: index_solid_queue_blocked_executions_for_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_blocked_executions_for_release ON public.solid_queue_blocked_executions USING btree (concurrency_key, priority, job_id);


--
-- Name: index_solid_queue_blocked_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_blocked_executions_on_job_id ON public.solid_queue_blocked_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_claimed_executions_on_job_id ON public.solid_queue_claimed_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_process_id_and_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_claimed_executions_on_process_id_and_job_id ON public.solid_queue_claimed_executions USING btree (process_id, job_id);


--
-- Name: index_solid_queue_dispatch_all; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_dispatch_all ON public.solid_queue_scheduled_executions USING btree (scheduled_at, priority, job_id);


--
-- Name: index_solid_queue_failed_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_failed_executions_on_job_id ON public.solid_queue_failed_executions USING btree (job_id);


--
-- Name: index_solid_queue_jobs_for_alerting; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_for_alerting ON public.solid_queue_jobs USING btree (scheduled_at, finished_at);


--
-- Name: index_solid_queue_jobs_for_filtering; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_for_filtering ON public.solid_queue_jobs USING btree (queue_name, finished_at);


--
-- Name: index_solid_queue_jobs_on_active_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_active_job_id ON public.solid_queue_jobs USING btree (active_job_id);


--
-- Name: index_solid_queue_jobs_on_class_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_class_name ON public.solid_queue_jobs USING btree (class_name);


--
-- Name: index_solid_queue_jobs_on_finished_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_finished_at ON public.solid_queue_jobs USING btree (finished_at);


--
-- Name: index_solid_queue_pauses_on_queue_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_pauses_on_queue_name ON public.solid_queue_pauses USING btree (queue_name);


--
-- Name: index_solid_queue_poll_all; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_poll_all ON public.solid_queue_ready_executions USING btree (priority, job_id);


--
-- Name: index_solid_queue_poll_by_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_poll_by_queue ON public.solid_queue_ready_executions USING btree (queue_name, priority, job_id);


--
-- Name: index_solid_queue_processes_on_last_heartbeat_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_processes_on_last_heartbeat_at ON public.solid_queue_processes USING btree (last_heartbeat_at);


--
-- Name: index_solid_queue_processes_on_name_and_supervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_processes_on_name_and_supervisor_id ON public.solid_queue_processes USING btree (name, supervisor_id);


--
-- Name: index_solid_queue_processes_on_supervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_processes_on_supervisor_id ON public.solid_queue_processes USING btree (supervisor_id);


--
-- Name: index_solid_queue_ready_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_ready_executions_on_job_id ON public.solid_queue_ready_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_job_id ON public.solid_queue_recurring_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_task_key_and_run_at; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_task_key_and_run_at ON public.solid_queue_recurring_executions USING btree (task_key, run_at);


--
-- Name: index_solid_queue_recurring_tasks_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_tasks_on_key ON public.solid_queue_recurring_tasks USING btree (key);


--
-- Name: index_solid_queue_recurring_tasks_on_static; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_recurring_tasks_on_static ON public.solid_queue_recurring_tasks USING btree (static);


--
-- Name: index_solid_queue_scheduled_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_scheduled_executions_on_job_id ON public.solid_queue_scheduled_executions USING btree (job_id);


--
-- Name: index_solid_queue_semaphores_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_semaphores_on_expires_at ON public.solid_queue_semaphores USING btree (expires_at);


--
-- Name: index_solid_queue_semaphores_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_semaphores_on_key ON public.solid_queue_semaphores USING btree (key);


--
-- Name: index_solid_queue_semaphores_on_key_and_value; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_semaphores_on_key_and_value ON public.solid_queue_semaphores USING btree (key, value);


--
-- Name: index_text_translations_on_language_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_text_translations_on_language_id ON public.text_translations USING btree (language_id);


--
-- Name: index_translation_trees_on_sheet_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_translation_trees_on_sheet_id ON public.translation_trees USING btree (sheet_id);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: index_users_on_normalized_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_normalized_email ON public.users USING btree (lower((email)::text));


--
-- Name: index_users_on_reset_password_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_reset_password_token ON public.users USING btree (reset_password_token);


--
-- Name: membership_language_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX membership_language_unique ON public.membership_languages USING btree (project_membership_id, language_id);


--
-- Name: unique_identifier_in_set; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_identifier_in_set ON public.language_identifiers USING btree (identifier_set_id, identifier);


--
-- Name: unique_language_in_identifier_set; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_language_in_identifier_set ON public.language_identifiers USING btree (identifier_set_id, language_id);


--
-- Name: translation_keys immutable_key; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_key BEFORE DELETE OR UPDATE ON public.translation_keys FOR EACH ROW EXECUTE FUNCTION public.immutable_translation_payload();


--
-- Name: text_translations immutable_text; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_text BEFORE DELETE OR UPDATE ON public.text_translations FOR EACH ROW EXECUTE FUNCTION public.immutable_translation_payload();


--
-- Name: languages language_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER language_owner BEFORE UPDATE ON public.languages FOR EACH ROW EXECUTE FUNCTION public.guard_content_owner();


--
-- Name: users last_global_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER last_global_owner AFTER DELETE OR UPDATE ON public.users DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.guard_last_global_owner();


--
-- Name: project_memberships last_project_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER last_project_owner AFTER DELETE OR UPDATE ON public.project_memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.guard_last_project_owner();


--
-- Name: membership_languages membership_language_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER membership_language_integrity BEFORE INSERT OR UPDATE ON public.membership_languages FOR EACH ROW EXECUTE FUNCTION public.guard_sheet_languages();


--
-- Name: project_memberships membership_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER membership_owner BEFORE UPDATE ON public.project_memberships FOR EACH ROW EXECUTE FUNCTION public.guard_content_owner();


--
-- Name: project_memberships project_member_capacity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER project_member_capacity BEFORE INSERT OR DELETE OR UPDATE ON public.project_memberships FOR EACH ROW EXECUTE FUNCTION public.guard_project_membership();


--
-- Name: recordings recording_delete_revision; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_delete_revision AFTER DELETE ON public.recordings REFERENCING OLD TABLE AS changed_records FOR EACH STATEMENT EXECUTE FUNCTION public.bump_translation_revision();


--
-- Name: recording_events recording_event_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_event_integrity BEFORE INSERT ON public.recording_events FOR EACH ROW EXECUTE FUNCTION public.guard_recording_event();


--
-- Name: recordings recording_identity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_identity BEFORE UPDATE ON public.recordings FOR EACH ROW EXECUTE FUNCTION public.guard_recording_identity();


--
-- Name: recordings recording_insert_revision; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_insert_revision AFTER INSERT ON public.recordings REFERENCING NEW TABLE AS changed_records FOR EACH STATEMENT EXECUTE FUNCTION public.bump_translation_revision();


--
-- Name: recordings recording_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_integrity BEFORE INSERT OR UPDATE ON public.recordings FOR EACH ROW EXECUTE FUNCTION public.guard_recording();


--
-- Name: recordings recording_update_revision; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recording_update_revision AFTER UPDATE ON public.recordings REFERENCING NEW TABLE AS changed_records FOR EACH STATEMENT EXECUTE FUNCTION public.bump_translation_revision();


--
-- Name: languages retained_language; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER retained_language AFTER UPDATE ON public.languages DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.guard_retained_language();


--
-- Name: users serialize_user_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER serialize_user_owner BEFORE DELETE OR UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.serialize_owner_mutation();


--
-- Name: sheets sheet_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sheet_integrity BEFORE INSERT OR UPDATE ON public.sheets FOR EACH ROW EXECUTE FUNCTION public.guard_sheet_structure();


--
-- Name: sheet_languages sheet_language_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sheet_language_integrity BEFORE INSERT OR UPDATE ON public.sheet_languages FOR EACH ROW EXECUTE FUNCTION public.guard_sheet_languages();


--
-- Name: translation_trees tree_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tree_owner BEFORE UPDATE ON public.translation_trees FOR EACH ROW EXECUTE FUNCTION public.guard_content_owner();


--
-- Name: recordings zz_recording_delimiter; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER zz_recording_delimiter BEFORE INSERT OR UPDATE ON public.recordings FOR EACH ROW EXECUTE FUNCTION public.guard_sheet_delimiter();


--
-- Name: sheets zz_sheet_delimiter; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER zz_sheet_delimiter BEFORE UPDATE ON public.sheets FOR EACH ROW EXECUTE FUNCTION public.guard_sheet_delimiter();


--
-- Name: recordings fk_rails_01ccc3f93a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recordings
    ADD CONSTRAINT fk_rails_01ccc3f93a FOREIGN KEY (parent_id) REFERENCES public.recordings(id);


--
-- Name: project_invites fk_rails_1f8289c57e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_invites
    ADD CONSTRAINT fk_rails_1f8289c57e FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: project_memberships fk_rails_26c4c0bd41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships
    ADD CONSTRAINT fk_rails_26c4c0bd41 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: sheets fk_rails_2b526e3a7f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sheets
    ADD CONSTRAINT fk_rails_2b526e3a7f FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: solid_queue_recurring_executions fk_rails_318a5533ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT fk_rails_318a5533ed FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: sheets fk_rails_3226d5ff13; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sheets
    ADD CONSTRAINT fk_rails_3226d5ff13 FOREIGN KEY (default_language_id) REFERENCES public.languages(id);


--
-- Name: solid_queue_failed_executions fk_rails_39bbc7a631; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT fk_rails_39bbc7a631 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: membership_languages fk_rails_3fc141a6fd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_languages
    ADD CONSTRAINT fk_rails_3fc141a6fd FOREIGN KEY (project_membership_id) REFERENCES public.project_memberships(id);


--
-- Name: export_requests fk_rails_3ff36be8eb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.export_requests
    ADD CONSTRAINT fk_rails_3ff36be8eb FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: text_translations fk_rails_44955cc5bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.text_translations
    ADD CONSTRAINT fk_rails_44955cc5bd FOREIGN KEY (language_id) REFERENCES public.languages(id);


--
-- Name: solid_queue_blocked_executions fk_rails_4cd34e2228; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT fk_rails_4cd34e2228 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: membership_languages fk_rails_61328c7010; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_languages
    ADD CONSTRAINT fk_rails_61328c7010 FOREIGN KEY (language_id) REFERENCES public.languages(id);


--
-- Name: recording_events fk_rails_6175619b12; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_events
    ADD CONSTRAINT fk_rails_6175619b12 FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: project_invites fk_rails_7aa33500d8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_invites
    ADD CONSTRAINT fk_rails_7aa33500d8 FOREIGN KEY (invited_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: export_requests fk_rails_7ab4c5fc15; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.export_requests
    ADD CONSTRAINT fk_rails_7ab4c5fc15 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: recording_events fk_rails_7fbf46cf3a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recording_events
    ADD CONSTRAINT fk_rails_7fbf46cf3a FOREIGN KEY (recording_id) REFERENCES public.recordings(id) ON DELETE CASCADE;


--
-- Name: solid_queue_ready_executions fk_rails_81fcbd66af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT fk_rails_81fcbd66af FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: sheet_languages fk_rails_97a9740b41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sheet_languages
    ADD CONSTRAINT fk_rails_97a9740b41 FOREIGN KEY (sheet_id) REFERENCES public.sheets(id);


--
-- Name: solid_queue_claimed_executions fk_rails_9cfe4d4944; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT fk_rails_9cfe4d4944 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: translation_trees fk_rails_a253064658; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_trees
    ADD CONSTRAINT fk_rails_a253064658 FOREIGN KEY (sheet_id) REFERENCES public.sheets(id);


--
-- Name: languages fk_rails_a44d178db8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.languages
    ADD CONSTRAINT fk_rails_a44d178db8 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: project_memberships fk_rails_aca847b4f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_memberships
    ADD CONSTRAINT fk_rails_aca847b4f5 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: language_identifiers fk_rails_b065a399cc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.language_identifiers
    ADD CONSTRAINT fk_rails_b065a399cc FOREIGN KEY (language_id) REFERENCES public.languages(id);


--
-- Name: language_identifiers fk_rails_bc9033fce7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.language_identifiers
    ADD CONSTRAINT fk_rails_bc9033fce7 FOREIGN KEY (identifier_set_id) REFERENCES public.identifier_sets(id);


--
-- Name: solid_queue_scheduled_executions fk_rails_c4316f352d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT fk_rails_c4316f352d FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: recordings fk_rails_cf612c75e6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recordings
    ADD CONSTRAINT fk_rails_cf612c75e6 FOREIGN KEY (translation_tree_id) REFERENCES public.translation_trees(id);


--
-- Name: identifier_sets fk_rails_cfe162eac5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identifier_sets
    ADD CONSTRAINT fk_rails_cfe162eac5 FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: sheet_languages fk_rails_f701e71187; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sheet_languages
    ADD CONSTRAINT fk_rails_f701e71187 FOREIGN KEY (language_id) REFERENCES public.languages(id);


--
-- Name: auth_identities fk_rails_fe3bac40a1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_identities
    ADD CONSTRAINT fk_rails_fe3bac40a1 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260921014000'),
('20260921013000'),
('20260921012000'),
('20260921011000'),
('20260921010000'),
('20260921000000'),
('20260920235900'),
('20260920230100'),
('20260920230000'),
('20260920220000'),
('20260920210000'),
('20260920200000'),
('20260920170000'),
('20260920161000'),
('20260920160000'),
('20260920107000'),
('20260920106000'),
('20260920105000'),
('20260920104000'),
('20260920103000'),
('20260920102000'),
('20260920101000'),
('20260920100000'),
('20260919180000'),
('20260919170000'),
('20260919160000'),
('20260919120000'),
('20260919090000'),
('20260915150000'),
('20260915120000'),
('20260915090000'),
('20260914040000'),
('20260914030000'),
('20260914020000'),
('20260914010000'),
('20260914000000'),
('20251227130124');

