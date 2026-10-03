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
-- Name: guard_catalog_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_catalog_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE node_project bigint; change_project bigint;
BEGIN
  SELECT project_id INTO STRICT node_project FROM catalog_nodes WHERE id=NEW.catalog_node_id;
  SELECT project_id INTO STRICT change_project FROM catalog_change_sets WHERE id=NEW.catalog_change_set_id;
  IF node_project<>change_project THEN RAISE EXCEPTION 'Event crosses projects'; END IF;
  IF NEW.previous_parent_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM catalog_nodes WHERE id=NEW.previous_parent_id AND project_id=node_project) THEN RAISE EXCEPTION 'Invalid prior parent'; END IF;
  IF NEW.action='payload_replaced' THEN
    IF NOT ((NEW.previous_payload_type='CatalogKey' AND EXISTS(SELECT 1 FROM catalog_keys WHERE id=NEW.previous_payload_id)) OR (NEW.previous_payload_type='CatalogText' AND EXISTS(SELECT 1 FROM catalog_texts WHERE id=NEW.previous_payload_id))) THEN RAISE EXCEPTION 'Invalid prior payload'; END IF;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: guard_catalog_node(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_catalog_node() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE p catalog_nodes;
BEGIN
  PERFORM 1 FROM projects WHERE id=NEW.project_id FOR UPDATE;
  IF NEW.payload_type NOT IN ('CatalogKey','CatalogText') THEN RAISE EXCEPTION 'Invalid payload type'; END IF;
  IF NEW.payload_type='CatalogKey' AND NOT EXISTS(SELECT 1 FROM catalog_keys WHERE id=NEW.payload_id) THEN RAISE EXCEPTION 'Missing key payload'; END IF;
  IF NEW.payload_type='CatalogText' AND NOT EXISTS(SELECT 1 FROM catalog_texts WHERE id=NEW.payload_id) THEN RAISE EXCEPTION 'Missing text payload'; END IF;
  IF NEW.parent_id IS NOT NULL THEN
    SELECT * INTO STRICT p FROM catalog_nodes WHERE id=NEW.parent_id;
    IF p.project_id<>NEW.project_id OR p.payload_type<>'CatalogKey' THEN RAISE EXCEPTION 'Invalid catalog parent'; END IF;
    IF EXISTS(WITH RECURSIVE a AS (SELECT id,parent_id FROM catalog_nodes WHERE id=NEW.parent_id UNION SELECT n.id,n.parent_id FROM catalog_nodes n JOIN a ON n.id=a.parent_id) SELECT 1 FROM a WHERE id=NEW.id) THEN RAISE EXCEPTION 'Catalog cycle'; END IF;
  ELSIF NEW.payload_type='CatalogText' THEN RAISE EXCEPTION 'Translation needs a key'; END IF;
  RETURN NEW;
END $$;


--
-- Name: guard_catalog_shape(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_catalog_shape() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM catalog_nodes n JOIN catalog_nodes p ON p.id=n.parent_id
    JOIN catalog_keys k ON p.payload_type='CatalogKey' AND k.id=p.payload_id
    WHERE n.project_id=NEW.project_id AND NOT n.deleted AND
      (p.deleted OR (n.payload_type='CatalogText' AND k.kind<>'scalar') OR (n.payload_type='CatalogKey' AND k.kind='scalar'))
  ) THEN RAISE EXCEPTION 'Invalid active catalog hierarchy'; END IF;
  IF EXISTS (
    SELECT 1 FROM catalog_nodes n JOIN catalog_keys k ON n.payload_type='CatalogKey' AND k.id=n.payload_id
    WHERE n.project_id=NEW.project_id AND NOT n.deleted
    GROUP BY n.parent_id,k.name HAVING count(*)>1
  ) THEN RAISE EXCEPTION 'Duplicate active key'; END IF;
  IF EXISTS (
    SELECT 1 FROM catalog_nodes n JOIN catalog_texts t ON n.payload_type='CatalogText' AND t.id=n.payload_id
    WHERE n.project_id=NEW.project_id AND NOT n.deleted
    GROUP BY n.parent_id,t.locale HAVING count(*)>1
  ) THEN RAISE EXCEPTION 'Duplicate active translation'; END IF;
  RETURN NULL;
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
-- Name: immutable_catalog_payload(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.immutable_catalog_payload() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'Catalog payloads and events are immutable'; END $$;


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
-- Name: catalog_change_sets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_change_sets (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    actor_id uuid,
    origin character varying DEFAULT 'manual'::character varying NOT NULL,
    status character varying DEFAULT 'accepted'::character varying NOT NULL,
    summary character varying NOT NULL,
    commit_sha character varying,
    github_author character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: catalog_change_sets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_change_sets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_change_sets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_change_sets_id_seq OWNED BY public.catalog_change_sets.id;


--
-- Name: catalog_draft_edits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_draft_edits (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    catalog_node_id bigint NOT NULL,
    actor_id uuid,
    previous_payload_type character varying,
    previous_payload_id bigint,
    previous_parent_id bigint,
    previous_deleted boolean,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: catalog_draft_edits_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_draft_edits_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_draft_edits_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_draft_edits_id_seq OWNED BY public.catalog_draft_edits.id;


--
-- Name: catalog_drafts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_drafts (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    catalog_node_id bigint NOT NULL,
    actor_id uuid,
    base_type character varying NOT NULL,
    base_id bigint NOT NULL,
    base_parent_id bigint,
    base_deleted boolean NOT NULL,
    payload_type character varying NOT NULL,
    payload_id bigint NOT NULL,
    parent_id bigint,
    deleted boolean NOT NULL,
    conflict boolean DEFAULT false NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: catalog_drafts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_drafts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_drafts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_drafts_id_seq OWNED BY public.catalog_drafts.id;


--
-- Name: catalog_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_events (
    id bigint NOT NULL,
    catalog_change_set_id bigint NOT NULL,
    catalog_node_id bigint NOT NULL,
    sequence integer NOT NULL,
    action character varying NOT NULL,
    previous_parent_id bigint,
    previous_payload_type character varying,
    previous_payload_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT catalog_event_union CHECK (((((action)::text = 'payload_replaced'::text) AND (previous_payload_type IS NOT NULL) AND (previous_payload_id IS NOT NULL) AND (previous_parent_id IS NULL)) OR (((action)::text = 'node_moved'::text) AND (previous_payload_type IS NULL) AND (previous_payload_id IS NULL)) OR (((action)::text = ANY ((ARRAY['node_created'::character varying, 'node_deleted'::character varying, 'node_reactivated'::character varying])::text[])) AND (previous_payload_type IS NULL) AND (previous_payload_id IS NULL) AND (previous_parent_id IS NULL))))
);


--
-- Name: catalog_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_events_id_seq OWNED BY public.catalog_events.id;


--
-- Name: catalog_git_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_git_revisions (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    commit_sha character varying NOT NULL,
    status character varying NOT NULL,
    error text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: catalog_git_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_git_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_git_revisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_git_revisions_id_seq OWNED BY public.catalog_git_revisions.id;


--
-- Name: catalog_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_keys (
    id bigint NOT NULL,
    name character varying NOT NULL,
    kind character varying NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    file_group character varying DEFAULT ''::character varying NOT NULL,
    CONSTRAINT catalog_key_shape CHECK ((((kind)::text = ANY ((ARRAY['scalar'::character varying, 'branch'::character varying, 'plural'::character varying])::text[])) AND (length((name)::text) > 0) AND (POSITION(('.'::text) IN (name)) = 0) AND ((name)::text !~ '\s'::text)))
);


--
-- Name: catalog_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_keys_id_seq OWNED BY public.catalog_keys.id;


--
-- Name: catalog_nodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_nodes (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    parent_id bigint,
    payload_type character varying NOT NULL,
    payload_id bigint NOT NULL,
    deleted boolean DEFAULT true NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: catalog_nodes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_nodes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_nodes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_nodes_id_seq OWNED BY public.catalog_nodes.id;


--
-- Name: catalog_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_reviews (
    id bigint NOT NULL,
    catalog_node_id bigint NOT NULL,
    actor_id uuid,
    source_digest character varying NOT NULL,
    translation_payload_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: catalog_reviews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_reviews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_reviews_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_reviews_id_seq OWNED BY public.catalog_reviews.id;


--
-- Name: catalog_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_tags (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    name character varying NOT NULL,
    commit_sha character varying NOT NULL,
    event_position bigint,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: catalog_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_tags_id_seq OWNED BY public.catalog_tags.id;


--
-- Name: catalog_texts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_texts (
    id bigint NOT NULL,
    locale character varying NOT NULL,
    value text NOT NULL
);


--
-- Name: catalog_texts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_texts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_texts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_texts_id_seq OWNED BY public.catalog_texts.id;


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
-- Name: github_app_configurations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.github_app_configurations (
    id bigint NOT NULL,
    app_id character varying NOT NULL,
    private_key text NOT NULL,
    webhook_secret text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT one_github_app_configuration CHECK ((id = 1))
);


--
-- Name: github_app_configurations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.github_app_configurations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: github_app_configurations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.github_app_configurations_id_seq OWNED BY public.github_app_configurations.id;


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
    CONSTRAINT language_identity CHECK (((length((name)::text) > 0) AND ((identifier)::text ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'::text))),
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
    source_locale character varying DEFAULT 'en'::character varying NOT NULL,
    revision bigint DEFAULT 0 NOT NULL,
    repository character varying,
    installation_id bigint,
    git_branch character varying,
    locale_directory character varying DEFAULT 'config/locales'::character varying NOT NULL,
    git_sha character varying,
    sync_error text,
    pull_request_number integer,
    last_published_at timestamp(6) without time zone,
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
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


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
-- Name: catalog_change_sets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_change_sets ALTER COLUMN id SET DEFAULT nextval('public.catalog_change_sets_id_seq'::regclass);


--
-- Name: catalog_draft_edits id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_draft_edits ALTER COLUMN id SET DEFAULT nextval('public.catalog_draft_edits_id_seq'::regclass);


--
-- Name: catalog_drafts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_drafts ALTER COLUMN id SET DEFAULT nextval('public.catalog_drafts_id_seq'::regclass);


--
-- Name: catalog_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_events ALTER COLUMN id SET DEFAULT nextval('public.catalog_events_id_seq'::regclass);


--
-- Name: catalog_git_revisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_git_revisions ALTER COLUMN id SET DEFAULT nextval('public.catalog_git_revisions_id_seq'::regclass);


--
-- Name: catalog_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_keys ALTER COLUMN id SET DEFAULT nextval('public.catalog_keys_id_seq'::regclass);


--
-- Name: catalog_nodes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_nodes ALTER COLUMN id SET DEFAULT nextval('public.catalog_nodes_id_seq'::regclass);


--
-- Name: catalog_reviews id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_reviews ALTER COLUMN id SET DEFAULT nextval('public.catalog_reviews_id_seq'::regclass);


--
-- Name: catalog_tags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_tags ALTER COLUMN id SET DEFAULT nextval('public.catalog_tags_id_seq'::regclass);


--
-- Name: catalog_texts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_texts ALTER COLUMN id SET DEFAULT nextval('public.catalog_texts_id_seq'::regclass);


--
-- Name: email_challenges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_challenges ALTER COLUMN id SET DEFAULT nextval('public.email_challenges_id_seq'::regclass);


--
-- Name: github_app_configurations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_app_configurations ALTER COLUMN id SET DEFAULT nextval('public.github_app_configurations_id_seq'::regclass);


--
-- Name: invitations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations ALTER COLUMN id SET DEFAULT nextval('public.invitations_id_seq'::regclass);


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
-- Name: catalog_change_sets catalog_change_sets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_change_sets
    ADD CONSTRAINT catalog_change_sets_pkey PRIMARY KEY (id);


--
-- Name: catalog_draft_edits catalog_draft_edits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_draft_edits
    ADD CONSTRAINT catalog_draft_edits_pkey PRIMARY KEY (id);


--
-- Name: catalog_drafts catalog_drafts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_drafts
    ADD CONSTRAINT catalog_drafts_pkey PRIMARY KEY (id);


--
-- Name: catalog_events catalog_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_events
    ADD CONSTRAINT catalog_events_pkey PRIMARY KEY (id);


--
-- Name: catalog_git_revisions catalog_git_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_git_revisions
    ADD CONSTRAINT catalog_git_revisions_pkey PRIMARY KEY (id);


--
-- Name: catalog_keys catalog_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_keys
    ADD CONSTRAINT catalog_keys_pkey PRIMARY KEY (id);


--
-- Name: catalog_nodes catalog_nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_nodes
    ADD CONSTRAINT catalog_nodes_pkey PRIMARY KEY (id);


--
-- Name: catalog_reviews catalog_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_reviews
    ADD CONSTRAINT catalog_reviews_pkey PRIMARY KEY (id);


--
-- Name: catalog_tags catalog_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_tags
    ADD CONSTRAINT catalog_tags_pkey PRIMARY KEY (id);


--
-- Name: catalog_texts catalog_texts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_texts
    ADD CONSTRAINT catalog_texts_pkey PRIMARY KEY (id);


--
-- Name: email_challenges email_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_challenges
    ADD CONSTRAINT email_challenges_pkey PRIMARY KEY (id);


--
-- Name: github_app_configurations github_app_configurations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_app_configurations
    ADD CONSTRAINT github_app_configurations_pkey PRIMARY KEY (id);


--
-- Name: invitations invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT invitations_pkey PRIMARY KEY (id);


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
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


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
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: catalog_review_node_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX catalog_review_node_unique ON public.catalog_reviews USING btree (catalog_node_id);


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
-- Name: index_catalog_change_sets_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_change_sets_on_actor_id ON public.catalog_change_sets USING btree (actor_id);


--
-- Name: index_catalog_change_sets_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_change_sets_on_project_id ON public.catalog_change_sets USING btree (project_id);


--
-- Name: index_catalog_draft_edits_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_draft_edits_on_actor_id ON public.catalog_draft_edits USING btree (actor_id);


--
-- Name: index_catalog_draft_edits_on_catalog_node_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_draft_edits_on_catalog_node_id ON public.catalog_draft_edits USING btree (catalog_node_id);


--
-- Name: index_catalog_draft_edits_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_draft_edits_on_project_id ON public.catalog_draft_edits USING btree (project_id);


--
-- Name: index_catalog_drafts_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_drafts_on_actor_id ON public.catalog_drafts USING btree (actor_id);


--
-- Name: index_catalog_drafts_on_catalog_node_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_catalog_drafts_on_catalog_node_id ON public.catalog_drafts USING btree (catalog_node_id);


--
-- Name: index_catalog_drafts_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_drafts_on_project_id ON public.catalog_drafts USING btree (project_id);


--
-- Name: index_catalog_events_on_catalog_change_set_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_events_on_catalog_change_set_id ON public.catalog_events USING btree (catalog_change_set_id);


--
-- Name: index_catalog_events_on_catalog_change_set_id_and_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_catalog_events_on_catalog_change_set_id_and_sequence ON public.catalog_events USING btree (catalog_change_set_id, sequence);


--
-- Name: index_catalog_events_on_catalog_node_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_events_on_catalog_node_id ON public.catalog_events USING btree (catalog_node_id);


--
-- Name: index_catalog_git_revisions_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_git_revisions_on_project_id ON public.catalog_git_revisions USING btree (project_id);


--
-- Name: index_catalog_git_revisions_on_project_id_and_commit_sha; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_catalog_git_revisions_on_project_id_and_commit_sha ON public.catalog_git_revisions USING btree (project_id, commit_sha);


--
-- Name: index_catalog_nodes_on_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_nodes_on_parent_id ON public.catalog_nodes USING btree (parent_id);


--
-- Name: index_catalog_nodes_on_payload_type_and_payload_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_nodes_on_payload_type_and_payload_id ON public.catalog_nodes USING btree (payload_type, payload_id);


--
-- Name: index_catalog_nodes_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_nodes_on_project_id ON public.catalog_nodes USING btree (project_id);


--
-- Name: index_catalog_reviews_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_reviews_on_actor_id ON public.catalog_reviews USING btree (actor_id);


--
-- Name: index_catalog_reviews_on_catalog_node_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_reviews_on_catalog_node_id ON public.catalog_reviews USING btree (catalog_node_id);


--
-- Name: index_catalog_tags_on_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_tags_on_project_id ON public.catalog_tags USING btree (project_id);


--
-- Name: index_catalog_tags_on_project_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_catalog_tags_on_project_id_and_name ON public.catalog_tags USING btree (project_id, name);


--
-- Name: index_email_challenges_on_email_and_purpose; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_challenges_on_email_and_purpose ON public.email_challenges USING btree (email, purpose);


--
-- Name: index_email_challenges_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_email_challenges_on_expires_at ON public.email_challenges USING btree (expires_at);


--
-- Name: index_invitations_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_invitations_on_email ON public.invitations USING btree (email);


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
-- Name: catalog_events catalog_event_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER catalog_event_integrity BEFORE INSERT ON public.catalog_events FOR EACH ROW EXECUTE FUNCTION public.guard_catalog_event();


--
-- Name: catalog_nodes catalog_node_integrity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER catalog_node_integrity BEFORE INSERT OR UPDATE ON public.catalog_nodes FOR EACH ROW EXECUTE FUNCTION public.guard_catalog_node();


--
-- Name: catalog_nodes catalog_shape; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER catalog_shape AFTER INSERT OR UPDATE ON public.catalog_nodes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.guard_catalog_shape();


--
-- Name: catalog_events immutable_catalog_events; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_catalog_events BEFORE UPDATE ON public.catalog_events FOR EACH ROW EXECUTE FUNCTION public.immutable_catalog_payload();


--
-- Name: catalog_keys immutable_catalog_keys; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_catalog_keys BEFORE UPDATE ON public.catalog_keys FOR EACH ROW EXECUTE FUNCTION public.immutable_catalog_payload();


--
-- Name: catalog_texts immutable_catalog_texts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_catalog_texts BEFORE UPDATE ON public.catalog_texts FOR EACH ROW EXECUTE FUNCTION public.immutable_catalog_payload();


--
-- Name: users last_global_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER last_global_owner AFTER DELETE OR UPDATE ON public.users DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.guard_last_global_owner();


--
-- Name: project_memberships last_project_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER last_project_owner AFTER DELETE OR UPDATE ON public.project_memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.guard_last_project_owner();


--
-- Name: project_memberships project_member_capacity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER project_member_capacity BEFORE INSERT OR DELETE OR UPDATE ON public.project_memberships FOR EACH ROW EXECUTE FUNCTION public.guard_project_membership();


--
-- Name: users serialize_user_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER serialize_user_owner BEFORE DELETE OR UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.serialize_owner_mutation();


--
-- Name: catalog_reviews fk_rails_02131ebbff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_reviews
    ADD CONSTRAINT fk_rails_02131ebbff FOREIGN KEY (catalog_node_id) REFERENCES public.catalog_nodes(id) ON DELETE CASCADE;


--
-- Name: catalog_draft_edits fk_rails_1b66e4409b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_draft_edits
    ADD CONSTRAINT fk_rails_1b66e4409b FOREIGN KEY (catalog_node_id) REFERENCES public.catalog_nodes(id) ON DELETE CASCADE;


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
-- Name: solid_queue_recurring_executions fk_rails_318a5533ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT fk_rails_318a5533ed FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: catalog_draft_edits fk_rails_35e019a423; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_draft_edits
    ADD CONSTRAINT fk_rails_35e019a423 FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: solid_queue_failed_executions fk_rails_39bbc7a631; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT fk_rails_39bbc7a631 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: catalog_tags fk_rails_3d3efdf5e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_tags
    ADD CONSTRAINT fk_rails_3d3efdf5e9 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: membership_languages fk_rails_3fc141a6fd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_languages
    ADD CONSTRAINT fk_rails_3fc141a6fd FOREIGN KEY (project_membership_id) REFERENCES public.project_memberships(id);


--
-- Name: catalog_reviews fk_rails_45c90e5685; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_reviews
    ADD CONSTRAINT fk_rails_45c90e5685 FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: catalog_drafts fk_rails_48a8d553a9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_drafts
    ADD CONSTRAINT fk_rails_48a8d553a9 FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE SET NULL;


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
-- Name: catalog_drafts fk_rails_627e7f0915; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_drafts
    ADD CONSTRAINT fk_rails_627e7f0915 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: project_invites fk_rails_7aa33500d8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_invites
    ADD CONSTRAINT fk_rails_7aa33500d8 FOREIGN KEY (invited_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: solid_queue_ready_executions fk_rails_81fcbd66af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT fk_rails_81fcbd66af FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: catalog_events fk_rails_927db5a1ac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_events
    ADD CONSTRAINT fk_rails_927db5a1ac FOREIGN KEY (catalog_node_id) REFERENCES public.catalog_nodes(id) ON DELETE CASCADE;


--
-- Name: catalog_change_sets fk_rails_96526986dd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_change_sets
    ADD CONSTRAINT fk_rails_96526986dd FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: catalog_nodes fk_rails_9b79972ae0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_nodes
    ADD CONSTRAINT fk_rails_9b79972ae0 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: solid_queue_claimed_executions fk_rails_9cfe4d4944; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT fk_rails_9cfe4d4944 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


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
-- Name: catalog_nodes fk_rails_b758e0000e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_nodes
    ADD CONSTRAINT fk_rails_b758e0000e FOREIGN KEY (parent_id) REFERENCES public.catalog_nodes(id);


--
-- Name: catalog_change_sets fk_rails_b8c955638c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_change_sets
    ADD CONSTRAINT fk_rails_b8c955638c FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: catalog_git_revisions fk_rails_bdad4d7ffd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_git_revisions
    ADD CONSTRAINT fk_rails_bdad4d7ffd FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: solid_queue_scheduled_executions fk_rails_c4316f352d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT fk_rails_c4316f352d FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: catalog_events fk_rails_da8627805e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_events
    ADD CONSTRAINT fk_rails_da8627805e FOREIGN KEY (catalog_change_set_id) REFERENCES public.catalog_change_sets(id) ON DELETE CASCADE;


--
-- Name: catalog_drafts fk_rails_eda0426685; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_drafts
    ADD CONSTRAINT fk_rails_eda0426685 FOREIGN KEY (catalog_node_id) REFERENCES public.catalog_nodes(id) ON DELETE CASCADE;


--
-- Name: catalog_draft_edits fk_rails_f6c34d0901; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_draft_edits
    ADD CONSTRAINT fk_rails_f6c34d0901 FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


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
('20261003000000'),
('20260930004000'),
('20260930003000'),
('20260930002000'),
('20260930001000'),
('20260930000000'),
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

