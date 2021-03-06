-------------------------------------------------------------------------------
--                             million trillion trillion
--                             |         trillion trillion
--                             |         |               trillion
--                             |         |               |   billion
--                             |         |               |   |   million
--                             |         |               |   |   |   thousand
--                             |         |               |   |   |   |
-- numeric(35,2) maxes out at $999,999,999,999,999,999,999,999,999,999,999.00.


CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;
COMMENT ON EXTENSION pg_stat_statements IS 'track execution statistics of all SQL statements executed';

\i sql/enforce-utc.sql


CREATE TYPE participant_number AS ENUM ('singular', 'plural');
CREATE TYPE status_of_1_0_payout AS ENUM
    ( 'too-little'
    , 'pending-application'
    , 'pending-review'
    , 'rejected'
    , 'pending-payout'
    , 'completed'
        );
CREATE TABLE participants
( username              text                        PRIMARY KEY
, session_token         text                        UNIQUE DEFAULT NULL
, session_expires       timestamp with time zone    DEFAULT (now() + INTERVAL '6 hours')
, ctime                 timestamp with time zone    NOT NULL DEFAULT CURRENT_TIMESTAMP
, claimed_time          timestamp with time zone    DEFAULT NULL
, is_admin              boolean                     NOT NULL DEFAULT FALSE
, balance               numeric(35,2)               NOT NULL DEFAULT 0.0
, anonymous_giving      boolean                     NOT NULL DEFAULT FALSE
, balanced_customer_href  text                      DEFAULT NULL
, is_suspicious         boolean                     DEFAULT NULL
, id                    bigserial                   NOT NULL UNIQUE
, username_lower        text                        NOT NULL UNIQUE
, api_key               text                        DEFAULT NULL
, avatar_url            text
, is_closed             boolean                     NOT NULL DEFAULT FALSE
, giving                numeric(35,2)               NOT NULL DEFAULT 0
, taking                numeric(35,2)               NOT NULL DEFAULT 0
, is_free_rider         boolean                     DEFAULT NULL
, email_address         text                        UNIQUE
, email_lang            text
, is_searchable         bool                        NOT NULL DEFAULT TRUE
, old_auth_usage        date
, notifications         text[]                      NOT NULL DEFAULT '{}'
, notify_charge         int                         DEFAULT 3
, braintree_customer_id text                        DEFAULT NULL
, ngiving_to            int                         NOT NULL DEFAULT 0
, ntaking_from          int                         NOT NULL DEFAULT 0
, status_of_1_0_payout  status_of_1_0_payout        NOT NULL DEFAULT 'completed'
, has_verified_identity boolean                     NOT NULL DEFAULT false
 );

CREATE FUNCTION complete_1_0_payout() RETURNS trigger AS $$
    BEGIN
        UPDATE participants
        SET status_of_1_0_payout='completed'
        WHERE id = NEW.id;
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_status_of_1_0_payout
    AFTER UPDATE OF balance ON participants
    FOR EACH ROW
    WHEN (OLD.balance > 0 AND NEW.balance = 0)
    EXECUTE PROCEDURE complete_1_0_payout();

CREATE INDEX participants_claimed_time ON participants (claimed_time DESC)
  WHERE is_suspicious IS NOT TRUE
    AND claimed_time IS NOT null;


CREATE TABLE elsewhere
( id                    serial          PRIMARY KEY
, platform              text            NOT NULL
, user_id               text            NOT NULL
, participant           text            NOT NULL REFERENCES participants ON UPDATE CASCADE ON DELETE RESTRICT
, user_name             text
-- Note: using "user_name" instead of "username" avoids having the same
--       column name in the participants and elsewhere tables.
, display_name          text
, email                 text
, avatar_url            text
, is_team               boolean         NOT NULL DEFAULT FALSE
, extra_info            json
, token                 json
, connect_token         text
, connect_expires       timestamptz
, UNIQUE (platform, user_id)
, UNIQUE (platform, participant)
 );

\i sql/elsewhere_with_participant.sql

CREATE INDEX elsewhere_participant ON elsewhere(participant);


-- tips -- all times a participant elects to tip another
CREATE TABLE tips
( id                    serial                      PRIMARY KEY
, ctime                 timestamp with time zone    NOT NULL
, mtime                 timestamp with time zone    NOT NULL DEFAULT CURRENT_TIMESTAMP
, tipper                text                        NOT NULL REFERENCES participants ON UPDATE CASCADE ON DELETE RESTRICT
, tippee                text                        NOT NULL REFERENCES participants ON UPDATE CASCADE ON DELETE RESTRICT
, amount                numeric(35,2)               NOT NULL
, is_funded             boolean                     NOT NULL DEFAULT false
 );

CREATE INDEX tips_all ON tips USING btree (tipper, tippee, mtime DESC);

CREATE VIEW current_tips AS
    SELECT DISTINCT ON (tipper, tippee) *
      FROM tips
  ORDER BY tipper, tippee, mtime DESC;

-- Allow updating is_funded via the current_tips view for convenience
CREATE FUNCTION update_tip() RETURNS trigger AS $$
    BEGIN
        UPDATE tips
           SET is_funded = NEW.is_funded
         WHERE id = NEW.id;
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_current_tip INSTEAD OF UPDATE ON current_tips
    FOR EACH ROW EXECUTE PROCEDURE update_tip();


CREATE TYPE context_type AS ENUM
    ('tip', 'take', 'final-gift', 'take-over', 'one-off');


-- paydays -- payday events, stats about them
CREATE TABLE paydays
( id                    serial                      PRIMARY KEY
, ts_start              timestamp with time zone    NOT NULL DEFAULT CURRENT_TIMESTAMP
, ts_end                timestamp with time zone    UNIQUE NOT NULL DEFAULT '1970-01-01T00:00:00+00'::timestamptz
, volume                numeric(35,2)               NOT NULL DEFAULT 0.00
, nusers                bigint                      NOT NULL DEFAULT 0
, stage                 integer                     DEFAULT 0
, nteams                integer                     NOT NULL DEFAULT 0
 );

CREATE FUNCTION current_payday() RETURNS paydays AS $$
    SELECT *
      FROM paydays
     WHERE ts_end='1970-01-01T00:00:00+00'::timestamptz;
$$ LANGUAGE sql;

CREATE FUNCTION current_payday_id() RETURNS int AS $$
    -- This is a function so we can use it in DEFAULTS for a column.
    SELECT id FROM current_payday();
$$ LANGUAGE sql;


-- transfers -- balance transfers from one user to another
CREATE TABLE transfers
( id                    serial                      PRIMARY KEY
, timestamp             timestamp with time zone    NOT NULL DEFAULT CURRENT_TIMESTAMP
, tipper                text                        NOT NULL REFERENCES participants ON UPDATE CASCADE ON DELETE RESTRICT
, tippee                text                        NOT NULL REFERENCES participants ON UPDATE CASCADE ON DELETE RESTRICT
, amount                numeric(35,2)               NOT NULL
, context               context_type                NOT NULL
, payday                integer                     DEFAULT NULL REFERENCES paydays
                                                        ON UPDATE RESTRICT
                                                        ON DELETE RESTRICT
 );

ALTER TABLE transfers ADD CONSTRAINT positive CHECK (amount > 0) NOT VALID;

CREATE INDEX transfers_timestamp_idx ON transfers (timestamp);
CREATE INDEX transfers_tipper_idx ON transfers (tipper);
CREATE INDEX transfers_tippee_idx ON transfers (tippee);


CREATE TYPE payment_net AS ENUM (
    'balanced-ba', 'balanced-cc', 'paypal', 'bitcoin', 'braintree-cc', 'cash', 'transferwise', 'dwolla', 'unknown'
);

CREATE TABLE exchange_routes
( id            serial         PRIMARY KEY
, participant   bigint         NOT NULL REFERENCES participants(id)
, network       payment_net    NOT NULL
, address       text           NOT NULL CHECK (address <> '')
, error         text           NOT NULL
, fee_cap       numeric(35,2)
, is_deleted    boolean        NOT NULL DEFAULT FALSE
, UNIQUE (participant, network, address)
 );

CREATE VIEW current_exchange_routes AS
    SELECT DISTINCT ON (participant, network) *
      FROM exchange_routes
     WHERE NOT is_deleted
  ORDER BY participant, network, id DESC;

CREATE CAST (current_exchange_routes AS exchange_routes) WITH INOUT;


CREATE TYPE exchange_status AS ENUM ('pre', 'pending', 'failed', 'succeeded', 'unknown');


-- exchanges -- when a participant moves cash between Gratipay and their bank
CREATE TABLE exchanges
( id                    serial                      PRIMARY KEY
, timestamp             timestamp with time zone    NOT NULL DEFAULT CURRENT_TIMESTAMP
, amount                numeric(35,2)               NOT NULL
, fee                   numeric(35,2)               NOT NULL
, participant           text                        NOT NULL REFERENCES participants ON UPDATE CASCADE ON DELETE RESTRICT
, recorder              text                        DEFAULT NULL REFERENCES participants ON UPDATE CASCADE ON DELETE RESTRICT
, note                  text                        DEFAULT NULL
, status                exchange_status             NOT NULL
, route                 bigint                      NOT NULL REFERENCES exchange_routes
, ref                   text                        DEFAULT NULL
 );


CREATE TABLE absorptions
( id                    serial                      PRIMARY KEY
, timestamp             timestamp with time zone    NOT NULL DEFAULT CURRENT_TIMESTAMP
, absorbed_was          text                        NOT NULL -- Not a foreign key!
, absorbed_by           text                        NOT NULL REFERENCES participants ON DELETE RESTRICT ON UPDATE CASCADE
, archived_as           text                        NOT NULL REFERENCES participants ON DELETE RESTRICT ON UPDATE RESTRICT
-- Here we actually want ON UPDATE RESTRICT as a sanity check:
-- noone should be changing usernames of absorbed accounts.
 );


CREATE TABLE community_members
( slug          text           NOT NULL
, participant   bigint         NOT NULL REFERENCES participants(id)
, ctime         timestamptz    NOT NULL
, mtime         timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP
, name          text           NOT NULL
, is_member     boolean        NOT NULL
 );

CREATE INDEX community_members_idx
    ON community_members (slug, participant, mtime DESC);

CREATE TABLE communities
( slug text PRIMARY KEY
, name text UNIQUE NOT NULL
, nmembers int NOT NULL
, ctime timestamptz NOT NULL
, CHECK (nmembers > 0)
 );

\i sql/upsert_community.sql

CREATE TRIGGER upsert_community BEFORE INSERT ON community_members
    FOR EACH ROW
    EXECUTE PROCEDURE upsert_community();

CREATE VIEW current_community_members AS
    SELECT DISTINCT ON (participant, slug) c.*
      FROM community_members c
  ORDER BY participant, slug, mtime DESC;


CREATE TABLE events
( id        serial      PRIMARY KEY
, ts        timestamp   NOT NULL DEFAULT CURRENT_TIMESTAMP
, type      text        NOT NULL
, payload   json
 );

CREATE INDEX events_ts ON events(ts ASC);
CREATE INDEX events_type ON events(type);


CREATE TABLE emails
( id                    serial                      PRIMARY KEY
, address               text                        NOT NULL
, verified              boolean                     DEFAULT NULL
                                                      CONSTRAINT verified_cant_be_false
                                                        -- Only use TRUE and NULL, so that the
                                                        -- unique constraint below functions
                                                        -- properly.
                                                        CHECK (verified IS NOT FALSE)
, nonce                 text
, verification_start    timestamp with time zone    NOT NULL
                                                      DEFAULT CURRENT_TIMESTAMP
, verification_end      timestamp with time zone
, participant_id        bigint                      NOT NULL
                                                      REFERENCES participants(id)
                                                      ON UPDATE RESTRICT
                                                      ON DELETE RESTRICT

, UNIQUE (address, verified) -- A verified email address can't be linked to multiple
                             -- participants. However, an *un*verified address *can*
                             -- be linked to multiple participants. We implement this
                             -- by using NULL instead of FALSE for the unverified
                             -- state, hence the check constraint on verified.
, UNIQUE (participant_id, address)
, CONSTRAINT emails_nonce_key UNIQUE (nonce)
 );


CREATE TABLE statements
( participant      bigint    NOT NULL REFERENCES participants(id)
, lang             text      NOT NULL
, content          text      NOT NULL CHECK (content <> '')
, search_vector    tsvector
, search_conf      regconfig NOT NULL
, content_scrubbed text      NOT NULL DEFAULT ''
, UNIQUE (participant, lang)
 );

CREATE INDEX statements_fts_idx ON statements USING gist(search_vector);

CREATE TRIGGER search_vector_update
    BEFORE INSERT OR UPDATE ON statements
    FOR EACH ROW EXECUTE PROCEDURE
    tsvector_update_trigger_column(search_vector, search_conf, content_scrubbed);

\i sql/enumerate.sql

-- Index user and community names

CREATE EXTENSION pg_trgm;

CREATE INDEX username_trgm_idx ON participants
    USING gist(username_lower gist_trgm_ops)
    WHERE claimed_time IS NOT NULL AND NOT is_closed;

CREATE INDEX community_trgm_idx ON communities
    USING gist(name gist_trgm_ops);

CREATE TABLE email_queue
( id             serial      PRIMARY KEY
, participant    bigint      NOT NULL REFERENCES participants(id)
, spt_name       text        NOT NULL
, context        bytea       NOT NULL
, user_initiated boolean     NOT NULL DEFAULT TRUE
, dead           boolean     NOT NULL DEFAULT FALSE
, ctime          timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
 );

CREATE TABLE balances_at
( participant  bigint         NOT NULL REFERENCES participants(id)
, at           timestamptz    NOT NULL
, balance      numeric(35,2)  NOT NULL
, UNIQUE (participant, at)
 );

-- teams - the entity that can receive and distribute payments
CREATE TYPE supported_image_types AS ENUM ('image/png', 'image/jpeg');
CREATE TABLE teams
( slug                  text                        PRIMARY KEY
, id                    bigserial                   NOT NULL UNIQUE
, ctime                 timestamp with time zone    NOT NULL DEFAULT CURRENT_TIMESTAMP
, slug_lower            text                        NOT NULL UNIQUE
, name                  text                        NOT NULL
, homepage              text                        NOT NULL
, product_or_service    text                        NOT NULL
, getting_involved      text
, getting_paid          text
, owner                 text                        NOT NULL REFERENCES participants
                                                        ON UPDATE CASCADE ON DELETE RESTRICT
, is_closed             boolean                     NOT NULL DEFAULT FALSE
, is_approved           boolean                     DEFAULT NULL
, receiving             numeric(35,2)               NOT NULL DEFAULT 0
, nreceiving_from       integer                     NOT NULL DEFAULT 0
, distributing          numeric(35,2)               NOT NULL DEFAULT 0
, ndistributing_to      integer                     NOT NULL DEFAULT 0
, revenue_model         text                        DEFAULT ''
, onboarding_url        text                        NOT NULL DEFAULT ''
, review_url            text                        DEFAULT NULL
, image_oid_original    oid                         NOT NULL DEFAULT 0
, image_oid_large       oid                         NOT NULL DEFAULT 0
, image_oid_small       oid                         NOT NULL DEFAULT 0
, image_type            supported_image_types
, available             numeric(35,2)               NOT NULL DEFAULT 0
, CONSTRAINT            available_not_negative CHECK ((available >= (0)::numeric))
 );


-- payment_instructions - A ~user instructs Gratipay to make voluntary payments to a Team.
CREATE TABLE payment_instructions
( id                    serial                      PRIMARY KEY
, ctime                 timestamp with time zone    NOT NULL
, mtime                 timestamp with time zone    NOT NULL DEFAULT CURRENT_TIMESTAMP
, amount                numeric(35,2)               NOT NULL
, is_funded             boolean                     NOT NULL DEFAULT false
, due                   numeric(35,2)               DEFAULT 0
, participant_id        bigint                      NOT NULL REFERENCES participants(id)
                                                        ON UPDATE RESTRICT ON DELETE RESTRICT
, team_id               bigint                      NOT NULL REFERENCES teams(id)
                                                        ON UPDATE RESTRICT ON DELETE RESTRICT
 );

CREATE VIEW current_payment_instructions AS
    SELECT DISTINCT ON (participant_id, team_id) *
      FROM payment_instructions
  ORDER BY participant_id, team_id, mtime DESC;

CREATE FUNCTION update_payment_instruction() RETURNS trigger AS $$
    BEGIN
        UPDATE payment_instructions
            SET is_funded = NEW.is_funded
                , due = NEW.due
            WHERE id = NEW.id;
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_current_payment_instruction
    INSTEAD OF UPDATE ON current_payment_instructions
    FOR EACH ROW EXECUTE PROCEDURE update_payment_instruction();

-- payments - movements of money back and forth between participants and teams

CREATE TYPE payment_direction AS ENUM
    ('to-team', 'to-participant');

CREATE TABLE payments
( id                    bigserial                   PRIMARY KEY
, timestamp             timestamp with time zone    NOT NULL DEFAULT CURRENT_TIMESTAMP
, participant           text                        NOT NULL REFERENCES participants
                                                        ON UPDATE CASCADE ON DELETE RESTRICT
, team                  text                        NOT NULL REFERENCES teams
                                                        ON UPDATE CASCADE ON DELETE RESTRICT
, amount                numeric(35,2)               NOT NULL
, direction             payment_direction           NOT NULL
, payday                int                         DEFAULT NULL REFERENCES paydays
                                                        ON UPDATE RESTRICT ON DELETE RESTRICT
, CONSTRAINT positive CHECK (amount > 0)
 );


CREATE TYPE status_of_1_0_balance AS ENUM
    ('unresolved', 'pending-payout', 'resolved');


CREATE TABLE countries -- http://www.iso.org/iso/country_codes
( id    bigserial   primary key
, code  text        NOT NULL UNIQUE
 );

\i sql/countries.sql


CREATE TABLE participant_identities
( id                bigserial       primary key
, participant_id    bigint          NOT NULL REFERENCES participants(id)
, country_id        bigint          NOT NULL REFERENCES countries(id)
, schema_name       text            NOT NULL
, info              bytea           NOT NULL
, _info_last_keyed  timestamptz     NOT NULL DEFAULT now()
, is_verified       boolean         NOT NULL DEFAULT false
, UNIQUE(participant_id, country_id)
 );


-- fail_if_no_email

CREATE FUNCTION fail_if_no_email() RETURNS trigger AS $$
    BEGIN
        IF (SELECT email_address FROM participants WHERE id=NEW.participant_id) IS NULL THEN
            RAISE EXCEPTION
            USING ERRCODE=23100
                , MESSAGE='This operation requires a verified participant email address.';
        END IF;
        RETURN NEW;
    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enforce_email_for_participant_identity
    BEFORE INSERT ON participant_identities
    FOR EACH ROW
    EXECUTE PROCEDURE fail_if_no_email();


-- takes - how participants express membership in teams

CREATE TABLE takes
( id                bigserial                   PRIMARY KEY
, ctime             timestamp with time zone    NOT NULL
, mtime             timestamp with time zone    NOT NULL DEFAULT now()
, participant_id    bigint                      NOT NULL REFERENCES participants(id)
, team_id           bigint                      NOT NULL REFERENCES teams(id)
, amount            numeric(35,2)               NOT NULL
, recorder_id       bigint                      NOT NULL REFERENCES participants(id)
, CONSTRAINT not_negative CHECK (amount >= 0)
    );

CREATE VIEW current_takes AS
    SELECT * FROM (
            SELECT DISTINCT ON (participant_id, team_id) t.*
            FROM takes t
            JOIN participants p ON p.id = t.participant_id
            WHERE p.is_suspicious IS NOT TRUE
        ORDER BY participant_id
                , team_id
                , mtime DESC
    ) AS anon WHERE amount > 0;


CREATE TABLE packages
( id                bigserial   PRIMARY KEY
, package_manager   text        NOT NULL
, name              text        NOT NULL
, description       text        NOT NULL
, emails            text[]      NOT NULL
, UNIQUE (package_manager, name)
    );


CREATE TABLE worker_coordination (npm_last_seq bigint not null default -1);
INSERT INTO worker_coordination DEFAULT VALUES;


CREATE TABLE claims
( nonce         text    NOT NULL REFERENCES emails(nonce)   ON DELETE CASCADE
                                                            ON UPDATE RESTRICT
, package_id    bigint  NOT NULL REFERENCES packages(id)    ON DELETE RESTRICT
                                                            ON UPDATE RESTRICT
, UNIQUE(nonce, package_id)
    );

CREATE TABLE teams_to_packages
( team_id       bigint UNIQUE REFERENCES teams(id) ON DELETE RESTRICT
, package_id    bigint UNIQUE REFERENCES packages(id) ON DELETE RESTRICT
    );


-- https://github.com/gratipay/gratipay.com/pull/4522

ALTER TABLE participants ADD COLUMN is_owner bool NOT NULL DEFAULT FALSE;
