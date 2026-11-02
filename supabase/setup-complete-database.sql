/*
  ===========================================================================
  EDAN — COMPLETE DATABASE SETUP
  ===========================================================================
  Run this entire script in your Supabase SQL Editor (supabase.com dashboard,
  your project, SQL Editor, New query, paste everything, Run).

  It creates ALL tables, functions, security policies, and storage buckets
  your website needs. It is safe to re-run — every statement uses
  IF NOT EXISTS or drops-then-recreates policies.

  After running this, also do these two things:
    1. Add your user ID to the admins table (see the INSERT at the very bottom).
    2. Add 5 sample rooms (see the INSERT statements at the very bottom).
  ===========================================================================
*/

-- ===========================================================================
-- 1. ADMINS TABLE + SITE-VIDEO BUCKET + IS_EDAN_ADMIN FUNCTION
-- ===========================================================================

CREATE TABLE IF NOT EXISTS admins (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE admins ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON admins TO authenticated;

DROP POLICY IF EXISTS "select_own_admin_row" ON admins;
CREATE POLICY "select_own_admin_row" ON admins FOR SELECT
  TO authenticated USING (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION is_edan_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM admins WHERE user_id = auth.uid());
$$;

REVOKE EXECUTE ON FUNCTION is_edan_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION is_edan_admin() TO authenticated;

INSERT INTO storage.buckets (id, name, public)
VALUES ('site-videos', 'site-videos', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS "admins_insert_site_videos" ON storage.objects;
CREATE POLICY "admins_insert_site_videos" ON storage.objects FOR INSERT
  TO authenticated WITH CHECK (bucket_id = 'site-videos' AND is_edan_admin());

DROP POLICY IF EXISTS "admins_update_site_videos" ON storage.objects;
CREATE POLICY "admins_update_site_videos" ON storage.objects FOR UPDATE
  TO authenticated USING (bucket_id = 'site-videos' AND is_edan_admin())
  WITH CHECK (bucket_id = 'site-videos' AND is_edan_admin());

DROP POLICY IF EXISTS "admins_delete_site_videos" ON storage.objects;
CREATE POLICY "admins_delete_site_videos" ON storage.objects FOR DELETE
  TO authenticated USING (bucket_id = 'site-videos' AND is_edan_admin());

-- ===========================================================================
-- 2. MEMBERSHIPS, VIDEO VIEWS, VIDEO UPLOADS
-- ===========================================================================

CREATE TABLE IF NOT EXISTS memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  member_email text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON memberships TO authenticated;

DROP POLICY IF EXISTS "select_own_membership" ON memberships;
CREATE POLICY "select_own_membership" ON memberships FOR SELECT
  TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "admins_select_memberships" ON memberships;
CREATE POLICY "admins_select_memberships" ON memberships FOR SELECT
  TO authenticated USING (is_edan_admin());

CREATE TABLE IF NOT EXISTS video_views (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE video_views ENABLE ROW LEVEL SECURITY;

GRANT INSERT ON video_views TO anon, authenticated;
GRANT SELECT ON video_views TO authenticated;

DROP POLICY IF EXISTS "anyone_insert_video_views" ON video_views;
CREATE POLICY "anyone_insert_video_views" ON video_views FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "admins_select_video_views" ON video_views;
CREATE POLICY "admins_select_video_views" ON video_views FOR SELECT
  TO authenticated USING (is_edan_admin());

CREATE TABLE IF NOT EXISTS video_uploads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  uploaded_by uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE SET NULL,
  file_name text NOT NULL,
  size_bytes bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE video_uploads ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT ON video_uploads TO authenticated;

DROP POLICY IF EXISTS "admins_insert_video_uploads" ON video_uploads;
CREATE POLICY "admins_insert_video_uploads" ON video_uploads FOR INSERT
  TO authenticated WITH CHECK (is_edan_admin() AND uploaded_by = auth.uid());

DROP POLICY IF EXISTS "admins_select_video_uploads" ON video_uploads;
CREATE POLICY "admins_select_video_uploads" ON video_uploads FOR SELECT
  TO authenticated USING (is_edan_admin());

-- ===========================================================================
-- 3. MEMBERSHIP APPLICATIONS + APPROVE/REJECT FUNCTIONS
-- ===========================================================================

ALTER TABLE memberships
  ADD COLUMN IF NOT EXISTS membership_tier text CHECK (membership_tier IN ('monthly', 'annual')),
  ADD COLUMN IF NOT EXISTS membership_status text NOT NULL DEFAULT 'pending'
    CHECK (membership_status IN ('pending', 'active', 'expired', 'rejected')),
  ADD COLUMN IF NOT EXISTS started_at timestamptz,
  ADD COLUMN IF NOT EXISTS expires_at timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS memberships_user_id_key ON memberships (user_id);

CREATE TABLE IF NOT EXISTS membership_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  applicant_email text NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz,
  reviewed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

ALTER TABLE membership_applications ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON membership_applications TO authenticated;

DROP POLICY IF EXISTS "select_own_membership_application" ON membership_applications;
CREATE POLICY "select_own_membership_application" ON membership_applications FOR SELECT
  TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "admins_select_membership_applications" ON membership_applications;
CREATE POLICY "admins_select_membership_applications" ON membership_applications FOR SELECT
  TO authenticated USING (is_edan_admin());

CREATE OR REPLACE FUNCTION approve_membership_application(
  p_application_id uuid,
  p_tier text,
  p_started_at timestamptz,
  p_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  app membership_applications%ROWTYPE;
BEGIN
  IF NOT is_edan_admin() THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  IF p_tier NOT IN ('monthly', 'annual') THEN
    RAISE EXCEPTION 'Choose monthly or annual membership';
  END IF;

  IF p_started_at IS NULL OR p_expires_at IS NULL OR p_expires_at <= p_started_at THEN
    RAISE EXCEPTION 'The end date must be after the start date';
  END IF;

  SELECT * INTO app FROM membership_applications WHERE id = p_application_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application not found';
  END IF;

  IF app.status <> 'pending' THEN
    RAISE EXCEPTION 'This application has already been reviewed';
  END IF;

  INSERT INTO memberships (user_id, member_email, membership_tier, membership_status, started_at, expires_at)
  VALUES (app.user_id, app.applicant_email, p_tier, 'active', p_started_at, p_expires_at)
  ON CONFLICT (user_id) DO UPDATE SET
    member_email = EXCLUDED.member_email,
    membership_tier = EXCLUDED.membership_tier,
    membership_status = 'active',
    started_at = EXCLUDED.started_at,
    expires_at = EXCLUDED.expires_at;

  UPDATE membership_applications
  SET status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
  WHERE id = app.id;
END;
$$;

CREATE OR REPLACE FUNCTION reject_membership_application(p_application_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  app membership_applications%ROWTYPE;
BEGIN
  IF NOT is_edan_admin() THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO app FROM membership_applications WHERE id = p_application_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application not found';
  END IF;

  IF app.status <> 'pending' THEN
    RAISE EXCEPTION 'This application has already been reviewed';
  END IF;

  UPDATE membership_applications
  SET status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid()
  WHERE id = app.id;
END;
$$;

REVOKE EXECUTE ON FUNCTION approve_membership_application(uuid, text, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION approve_membership_application(uuid, text, timestamptz, timestamptz) TO authenticated;

REVOKE EXECUTE ON FUNCTION reject_membership_application(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION reject_membership_application(uuid) TO authenticated;

-- ===========================================================================
-- 4. MEMBERSHIP APPLICATION TIER COLUMN + INSERT POLICY
-- ===========================================================================

ALTER TABLE membership_applications
  ADD COLUMN IF NOT EXISTS membership_tier text CHECK (membership_tier IN ('monthly', 'annual'));

GRANT INSERT ON membership_applications TO authenticated;

DROP POLICY IF EXISTS "insert_own_pending_membership_application" ON membership_applications;
CREATE POLICY "insert_own_pending_membership_application" ON membership_applications FOR INSERT
  TO authenticated WITH CHECK (auth.uid() = user_id AND status = 'pending');

-- ===========================================================================
-- 5. PAYSTACK PAYMENT TRANSACTIONS + WEBHOOK EVENT LOG
-- ===========================================================================

CREATE TABLE IF NOT EXISTS payment_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reference text NOT NULL UNIQUE,
  membership_application_id uuid NOT NULL REFERENCES membership_applications(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  plan text NOT NULL CHECK (plan IN ('monthly', 'annual')),
  amount_pesewas integer NOT NULL CHECK (amount_pesewas > 0),
  currency text NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'success', 'failed', 'abandoned')),
  paystack_transaction_id bigint UNIQUE,
  paid_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payment_transactions_application_id_idx ON payment_transactions (membership_application_id);
CREATE INDEX IF NOT EXISTS payment_transactions_user_id_idx ON payment_transactions (user_id);

ALTER TABLE payment_transactions ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON payment_transactions TO authenticated;

DROP POLICY IF EXISTS "select_own_payment_transactions" ON payment_transactions;
CREATE POLICY "select_own_payment_transactions" ON payment_transactions FOR SELECT
  TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "admins_select_payment_transactions" ON payment_transactions;
CREATE POLICY "admins_select_payment_transactions" ON payment_transactions FOR SELECT
  TO authenticated USING (is_edan_admin());

CREATE TABLE IF NOT EXISTS paystack_events (
  event_key text PRIMARY KEY,
  event_type text NOT NULL,
  reference text,
  outcome text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE paystack_events ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION record_paystack_event(
  p_event_key text,
  p_event_type text,
  p_reference text,
  p_verified_transaction_id bigint,
  p_verified_amount_pesewas integer,
  p_verified_currency text,
  p_verified_paid_at timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pay payment_transactions%ROWTYPE;
  result text;
BEGIN
  IF p_event_type <> 'charge.success' OR p_reference IS NULL THEN
    result := 'ignored';
  ELSE
    SELECT * INTO pay FROM payment_transactions WHERE reference = p_reference FOR UPDATE;

    IF NOT FOUND THEN
      result := 'unmatched';
    ELSIF p_verified_transaction_id IS NULL THEN
      result := 'not_successful';
    ELSIF pay.status = 'success' THEN
      result := 'already_recorded';
    ELSIF p_verified_amount_pesewas IS DISTINCT FROM pay.amount_pesewas
      OR p_verified_currency IS DISTINCT FROM pay.currency THEN
      result := 'amount_mismatch';
    ELSE
      UPDATE payment_transactions
      SET status = 'success',
          paystack_transaction_id = p_verified_transaction_id,
          paid_at = p_verified_paid_at,
          updated_at = now()
      WHERE id = pay.id;
      result := 'recorded';
    END IF;
  END IF;

  INSERT INTO paystack_events (event_key, event_type, reference, outcome)
  VALUES (p_event_key, p_event_type, p_reference, result)
  ON CONFLICT (event_key) DO NOTHING;

  RETURN result;
END;
$$;

REVOKE EXECUTE ON FUNCTION record_paystack_event(text, text, text, bigint, integer, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION record_paystack_event(text, text, text, bigint, integer, text, timestamptz) TO service_role;

-- ===========================================================================
-- 6. PAYMENT RECEIPT SENT TRACKING
-- ===========================================================================

ALTER TABLE payment_transactions
  ADD COLUMN IF NOT EXISTS receipt_sent_at timestamptz;

GRANT SELECT ON payment_transactions TO service_role;
GRANT UPDATE (receipt_sent_at) ON payment_transactions TO service_role;

-- ===========================================================================
-- 7. STAY ROOMS, BOOKINGS, AND ROOM BLOCKS
-- ===========================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE IF NOT EXISTS stay_rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stay_rooms_name_unique UNIQUE (name)
);

CREATE TABLE IF NOT EXISTS stay_bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_reference text NOT NULL UNIQUE
    DEFAULT ('EDN-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  room_id uuid NOT NULL REFERENCES stay_rooms(id) ON DELETE RESTRICT,
  check_in date NOT NULL,
  check_out date NOT NULL,
  guests smallint NOT NULL CHECK (guests BETWEEN 1 AND 2),
  breakfast_included boolean NOT NULL DEFAULT false,
  nightly_rate_ghs integer NOT NULL CHECK (nightly_rate_ghs > 0),
  total_ghs integer NOT NULL CHECK (total_ghs > 0),
  status text NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('pending_payment', 'confirmed', 'cancelled', 'completed', 'payment_failed')),
  source text NOT NULL CHECK (source IN ('online', 'manual')),
  guest_name text NOT NULL CHECK (length(btrim(guest_name)) > 0),
  guest_email text NOT NULL CHECK (length(btrim(guest_email)) > 0),
  guest_phone text NOT NULL CHECK (length(btrim(guest_phone)) > 0),
  notes text NOT NULL DEFAULT '',
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz,
  CONSTRAINT stay_bookings_dates_valid CHECK (check_out > check_in),
  CONSTRAINT stay_bookings_total_matches_nights
    CHECK (total_ghs = (check_out - check_in) * nightly_rate_ghs),
  CONSTRAINT stay_bookings_no_overlap EXCLUDE USING gist (
    room_id WITH =,
    daterange(check_in, check_out, '[)') WITH &&
  ) WHERE (status IN ('confirmed', 'completed'))
);

CREATE INDEX IF NOT EXISTS stay_bookings_check_in_idx ON stay_bookings (check_in);
CREATE INDEX IF NOT EXISTS stay_bookings_room_idx ON stay_bookings (room_id);

CREATE TABLE IF NOT EXISTS stay_room_blocks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES stay_rooms(id) ON DELETE CASCADE,
  starts_on date NOT NULL,
  ends_on date NOT NULL,
  reason text NOT NULL DEFAULT '',
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stay_room_blocks_dates_valid CHECK (ends_on > starts_on),
  CONSTRAINT stay_room_blocks_no_overlap EXCLUDE USING gist (
    room_id WITH =,
    daterange(starts_on, ends_on, '[)') WITH &&
  )
);

CREATE INDEX IF NOT EXISTS stay_room_blocks_room_idx ON stay_room_blocks (room_id);

ALTER TABLE stay_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE stay_bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE stay_room_blocks ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT ON stay_rooms TO authenticated;
GRANT UPDATE (name, is_active) ON stay_rooms TO authenticated;
GRANT SELECT ON stay_bookings TO authenticated;
GRANT SELECT, DELETE ON stay_room_blocks TO authenticated;

DROP POLICY IF EXISTS "admins_select_stay_rooms" ON stay_rooms;
CREATE POLICY "admins_select_stay_rooms" ON stay_rooms FOR SELECT
  TO authenticated USING (is_edan_admin());

DROP POLICY IF EXISTS "admins_insert_stay_rooms" ON stay_rooms;
CREATE POLICY "admins_insert_stay_rooms" ON stay_rooms FOR INSERT
  TO authenticated WITH CHECK (is_edan_admin());

DROP POLICY IF EXISTS "admins_update_stay_rooms" ON stay_rooms;
CREATE POLICY "admins_update_stay_rooms" ON stay_rooms FOR UPDATE
  TO authenticated USING (is_edan_admin()) WITH CHECK (is_edan_admin());

DROP POLICY IF EXISTS "admins_select_stay_bookings" ON stay_bookings;
CREATE POLICY "admins_select_stay_bookings" ON stay_bookings FOR SELECT
  TO authenticated USING (is_edan_admin());

DROP POLICY IF EXISTS "admins_select_stay_room_blocks" ON stay_room_blocks;
CREATE POLICY "admins_select_stay_room_blocks" ON stay_room_blocks FOR SELECT
  TO authenticated USING (is_edan_admin());

DROP POLICY IF EXISTS "admins_delete_stay_room_blocks" ON stay_room_blocks;
CREATE POLICY "admins_delete_stay_room_blocks" ON stay_room_blocks FOR DELETE
  TO authenticated USING (is_edan_admin());

-- ===========================================================================
-- 8. ADMIN STAY BOOKING FUNCTIONS
-- ===========================================================================

CREATE OR REPLACE FUNCTION admin_create_manual_booking(
  p_room_id uuid,
  p_check_in date,
  p_check_out date,
  p_guests integer,
  p_breakfast_included boolean,
  p_guest_name text,
  p_guest_email text,
  p_guest_phone text,
  p_notes text
)
RETURNS stay_bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate integer;
  v_booking stay_bookings;
BEGIN
  IF NOT is_edan_admin() THEN
    RAISE EXCEPTION 'You are not authorised to manage bookings.' USING ERRCODE = '42501';
  END IF;

  IF p_check_in IS NULL OR p_check_out IS NULL OR p_check_out <= p_check_in THEN
    RAISE EXCEPTION 'Check-out must be at least one night after check-in.';
  END IF;

  IF p_check_in < CURRENT_DATE THEN
    RAISE EXCEPTION 'Check-in cannot be in the past.';
  END IF;

  IF p_guests IS NULL OR p_guests NOT BETWEEN 1 AND 2 THEN
    RAISE EXCEPTION 'Each room holds one or two guests.';
  END IF;

  IF length(btrim(coalesce(p_guest_name, ''))) = 0
     OR length(btrim(coalesce(p_guest_phone, ''))) = 0
     OR length(btrim(coalesce(p_guest_email, ''))) = 0 THEN
    RAISE EXCEPTION 'Guest name, email and phone are required.';
  END IF;

  PERFORM 1 FROM stay_rooms WHERE id = p_room_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That room is not available for bookings.';
  END IF;

  v_rate := CASE WHEN coalesce(p_breakfast_included, false) THEN 700 ELSE 650 END;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_room_id::text, 0));

  IF EXISTS (
    SELECT 1 FROM stay_bookings b
    WHERE b.room_id = p_room_id
      AND b.status IN ('confirmed', 'completed')
      AND daterange(b.check_in, b.check_out, '[)') && daterange(p_check_in, p_check_out, '[)')
  ) OR EXISTS (
    SELECT 1 FROM stay_room_blocks k
    WHERE k.room_id = p_room_id
      AND daterange(k.starts_on, k.ends_on, '[)') && daterange(p_check_in, p_check_out, '[)')
  ) THEN
    RAISE EXCEPTION 'That room is already booked or blocked for these dates.';
  END IF;

  INSERT INTO stay_bookings (
    room_id, check_in, check_out, guests, breakfast_included,
    nightly_rate_ghs, total_ghs, status, source,
    guest_name, guest_email, guest_phone, notes, created_by
  ) VALUES (
    p_room_id, p_check_in, p_check_out, p_guests, coalesce(p_breakfast_included, false),
    v_rate, (p_check_out - p_check_in) * v_rate, 'confirmed', 'manual',
    btrim(p_guest_name), btrim(p_guest_email), btrim(p_guest_phone), coalesce(p_notes, ''), auth.uid()
  )
  RETURNING * INTO v_booking;

  RETURN v_booking;
END;
$$;

CREATE OR REPLACE FUNCTION admin_block_room(
  p_room_id uuid,
  p_starts_on date,
  p_ends_on date,
  p_reason text
)
RETURNS stay_room_blocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_block stay_room_blocks;
BEGIN
  IF NOT is_edan_admin() THEN
    RAISE EXCEPTION 'You are not authorised to manage bookings.' USING ERRCODE = '42501';
  END IF;

  IF p_starts_on IS NULL OR p_ends_on IS NULL OR p_ends_on <= p_starts_on THEN
    RAISE EXCEPTION 'The blocked end date must be after the start date.';
  END IF;

  PERFORM 1 FROM stay_rooms WHERE id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That room does not exist.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_room_id::text, 0));

  IF EXISTS (
    SELECT 1 FROM stay_bookings b
    WHERE b.room_id = p_room_id
      AND b.status IN ('confirmed', 'completed')
      AND daterange(b.check_in, b.check_out, '[)') && daterange(p_starts_on, p_ends_on, '[)')
  ) THEN
    RAISE EXCEPTION 'A booking already covers part of these dates. Cancel it before blocking the room.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM stay_room_blocks k
    WHERE k.room_id = p_room_id
      AND daterange(k.starts_on, k.ends_on, '[)') && daterange(p_starts_on, p_ends_on, '[)')
  ) THEN
    RAISE EXCEPTION 'This room is already blocked for part of these dates.';
  END IF;

  INSERT INTO stay_room_blocks (room_id, starts_on, ends_on, reason, created_by)
  VALUES (p_room_id, p_starts_on, p_ends_on, coalesce(btrim(p_reason), ''), auth.uid())
  RETURNING * INTO v_block;

  RETURN v_block;
END;
$$;

CREATE OR REPLACE FUNCTION admin_set_booking_status(
  p_booking_id uuid,
  p_status text
)
RETURNS stay_bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking stay_bookings;
BEGIN
  IF NOT is_edan_admin() THEN
    RAISE EXCEPTION 'You are not authorised to manage bookings.' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'Bookings can only be marked completed or cancelled here.';
  END IF;

  SELECT * INTO v_booking FROM stay_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That booking does not exist.';
  END IF;

  IF v_booking.status <> 'confirmed' THEN
    RAISE EXCEPTION 'Only confirmed bookings can be changed.';
  END IF;

  UPDATE stay_bookings
  SET status = p_status,
      updated_at = now(),
      cancelled_at = CASE WHEN p_status = 'cancelled' THEN now() ELSE cancelled_at END
  WHERE id = p_booking_id
  RETURNING * INTO v_booking;

  RETURN v_booking;
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_create_manual_booking(uuid, date, date, integer, boolean, text, text, text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION admin_block_room(uuid, date, date, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION admin_set_booking_status(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_create_manual_booking(uuid, date, date, integer, boolean, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_block_room(uuid, date, date, text) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_set_booking_status(uuid, text) TO authenticated;

-- ===========================================================================
-- 9. STAY ONLINE BOOKING COLUMNS + PAYMENT EVENT LOG
-- ===========================================================================

ALTER TABLE stay_bookings
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS paystack_reference text UNIQUE,
  ADD COLUMN IF NOT EXISTS paystack_authorization_url text,
  ADD COLUMN IF NOT EXISTS hold_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS paid_amount_pesewas integer,
  ADD COLUMN IF NOT EXISTS paystack_transaction_id bigint,
  ADD COLUMN IF NOT EXISTS paid_at timestamptz,
  ADD COLUMN IF NOT EXISTS payment_note text NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS stay_bookings_user_idx ON stay_bookings (user_id);

DROP POLICY IF EXISTS "guests_select_own_stay_bookings" ON stay_bookings;
CREATE POLICY "guests_select_own_stay_bookings" ON stay_bookings FOR SELECT
  TO authenticated USING (user_id = auth.uid());

CREATE TABLE IF NOT EXISTS stay_payment_events (
  event_key text PRIMARY KEY,
  event_type text NOT NULL,
  reference text,
  received_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE stay_payment_events ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT ON stay_payment_events TO service_role;
GRANT SELECT, UPDATE ON stay_bookings TO service_role;

-- ===========================================================================
-- 10. STAY ONLINE BOOKING FUNCTIONS
-- ===========================================================================

CREATE OR REPLACE FUNCTION stay_room_availability(p_check_in date, p_check_out date)
RETURNS TABLE (available_room_id uuid, available_room_name text, is_available boolean)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_check_in IS NULL OR p_check_out IS NULL OR p_check_out <= p_check_in THEN
    RAISE EXCEPTION 'Check-out must be at least one night after check-in.';
  END IF;

  IF p_check_in < CURRENT_DATE THEN
    RAISE EXCEPTION 'Check-in cannot be in the past.';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.name,
    NOT EXISTS (
      SELECT 1 FROM stay_bookings b
      WHERE b.room_id = r.id
        AND (
          b.status IN ('confirmed', 'completed')
          OR (b.status = 'pending_payment' AND b.hold_expires_at > now())
        )
        AND daterange(b.check_in, b.check_out, '[)') && daterange(p_check_in, p_check_out, '[)')
    ) AND NOT EXISTS (
      SELECT 1 FROM stay_room_blocks k
      WHERE k.room_id = r.id
        AND daterange(k.starts_on, k.ends_on, '[)') && daterange(p_check_in, p_check_out, '[)')
    )
  FROM stay_rooms r
  WHERE r.is_active
  ORDER BY r.name;
END;
$$;

CREATE OR REPLACE FUNCTION create_stay_hold(
  p_room_id uuid,
  p_check_in date,
  p_check_out date,
  p_guests integer,
  p_breakfast_included boolean,
  p_guest_name text,
  p_guest_email text,
  p_guest_phone text
)
RETURNS stay_bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate integer;
  v_booking stay_bookings;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Please log in to book a room.' USING ERRCODE = '42501';
  END IF;

  IF p_check_in IS NULL OR p_check_out IS NULL OR p_check_out <= p_check_in THEN
    RAISE EXCEPTION 'Check-out must be at least one night after check-in.';
  END IF;

  IF p_check_in < CURRENT_DATE THEN
    RAISE EXCEPTION 'Check-in cannot be in the past.';
  END IF;

  IF p_guests IS NULL OR p_guests NOT BETWEEN 1 AND 2 THEN
    RAISE EXCEPTION 'Each room holds one or two guests.';
  END IF;

  IF length(btrim(coalesce(p_guest_name, ''))) = 0
     OR length(btrim(coalesce(p_guest_email, ''))) = 0
     OR length(btrim(coalesce(p_guest_phone, ''))) = 0 THEN
    RAISE EXCEPTION 'Please enter your name, email and phone number.';
  END IF;

  PERFORM 1 FROM stay_rooms WHERE id = p_room_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That room is not available for booking.';
  END IF;

  UPDATE stay_bookings
  SET status = 'payment_failed',
      updated_at = now(),
      payment_note = 'The payment window closed before payment was completed.'
  WHERE status = 'pending_payment' AND hold_expires_at <= now();

  v_rate := CASE WHEN coalesce(p_breakfast_included, false) THEN 700 ELSE 650 END;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_room_id::text, 0));

  IF EXISTS (
    SELECT 1 FROM stay_bookings b
    WHERE b.room_id = p_room_id
      AND (
        b.status IN ('confirmed', 'completed')
        OR (b.status = 'pending_payment' AND b.hold_expires_at > now())
      )
      AND daterange(b.check_in, b.check_out, '[)') && daterange(p_check_in, p_check_out, '[)')
  ) OR EXISTS (
    SELECT 1 FROM stay_room_blocks k
    WHERE k.room_id = p_room_id
      AND daterange(k.starts_on, k.ends_on, '[)') && daterange(p_check_in, p_check_out, '[)')
  ) THEN
    RAISE EXCEPTION 'Sorry, that room has just been taken for these dates. Please choose another room or dates.';
  END IF;

  INSERT INTO stay_bookings (
    room_id, user_id, check_in, check_out, guests, breakfast_included,
    nightly_rate_ghs, total_ghs, status, source, hold_expires_at, paystack_reference,
    guest_name, guest_email, guest_phone
  ) VALUES (
    p_room_id, auth.uid(), p_check_in, p_check_out, p_guests, coalesce(p_breakfast_included, false),
    v_rate, (p_check_out - p_check_in) * v_rate, 'pending_payment', 'online',
    now() + interval '15 minutes',
    'EDNSTAY-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    btrim(p_guest_name), btrim(p_guest_email), btrim(p_guest_phone)
  )
  RETURNING * INTO v_booking;

  RETURN v_booking;
END;
$$;

CREATE OR REPLACE FUNCTION prepare_stay_payment(p_booking_id uuid)
RETURNS stay_bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking stay_bookings;
BEGIN
  SELECT * INTO v_booking FROM stay_bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND OR v_booking.status <> 'pending_payment' THEN
    RAISE EXCEPTION 'This booking is no longer waiting for payment. Please start again.';
  END IF;

  IF v_booking.hold_expires_at <= now() THEN
    RAISE EXCEPTION 'Your 15-minute hold has expired. Please start the booking again.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_booking.room_id::text, 0));

  IF EXISTS (
    SELECT 1 FROM stay_bookings b
    WHERE b.room_id = v_booking.room_id
      AND b.id <> v_booking.id
      AND (
        b.status IN ('confirmed', 'completed')
        OR (b.status = 'pending_payment' AND b.hold_expires_at > now())
      )
      AND daterange(b.check_in, b.check_out, '[)') && daterange(v_booking.check_in, v_booking.check_out, '[)')
  ) OR EXISTS (
    SELECT 1 FROM stay_room_blocks k
    WHERE k.room_id = v_booking.room_id
      AND daterange(k.starts_on, k.ends_on, '[)') && daterange(v_booking.check_in, v_booking.check_out, '[)')
  ) THEN
    RAISE EXCEPTION 'Sorry, these dates are no longer available for this room. Please start again.';
  END IF;

  RETURN v_booking;
END;
$$;

CREATE OR REPLACE FUNCTION confirm_stay_payment(
  p_reference text,
  p_transaction_id bigint,
  p_amount_pesewas integer,
  p_currency text,
  p_paid_at timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking stay_bookings;
  v_conflict boolean;
BEGIN
  SELECT * INTO v_booking FROM stay_bookings WHERE paystack_reference = p_reference FOR UPDATE;

  IF NOT FOUND THEN
    RETURN 'unknown_reference';
  END IF;

  IF v_booking.status = 'confirmed' THEN
    RETURN 'already_confirmed';
  END IF;

  IF v_booking.status NOT IN ('pending_payment', 'payment_failed') THEN
    RETURN 'not_confirmable';
  END IF;

  IF p_currency IS DISTINCT FROM 'GHS' OR p_amount_pesewas IS DISTINCT FROM v_booking.total_ghs * 100 THEN
    UPDATE stay_bookings
    SET status = 'cancelled',
        cancelled_at = now(),
        updated_at = now(),
        paystack_transaction_id = p_transaction_id,
        paid_amount_pesewas = p_amount_pesewas,
        paid_at = p_paid_at,
        payment_note = 'Payment amount or currency did not match this booking. Refund required.'
    WHERE id = v_booking.id;
    RETURN 'amount_mismatch';
  END IF;

  v_conflict := EXISTS (
    SELECT 1 FROM stay_bookings b
    WHERE b.room_id = v_booking.room_id
      AND b.id <> v_booking.id
      AND b.status IN ('confirmed', 'completed')
      AND daterange(b.check_in, b.check_out, '[)') && daterange(v_booking.check_in, v_booking.check_out, '[)')
  ) OR EXISTS (
    SELECT 1 FROM stay_room_blocks k
    WHERE k.room_id = v_booking.room_id
      AND daterange(k.starts_on, k.ends_on, '[)') && daterange(v_booking.check_in, v_booking.check_out, '[)')
  );

  IF v_conflict THEN
    UPDATE stay_bookings
    SET status = 'cancelled',
        cancelled_at = now(),
        updated_at = now(),
        paystack_transaction_id = p_transaction_id,
        paid_amount_pesewas = p_amount_pesewas,
        paid_at = p_paid_at,
        payment_note = 'Payment was received after the hold expired and these dates were taken. Refund required.'
    WHERE id = v_booking.id;
    RETURN 'conflict_refund_required';
  END IF;

  UPDATE stay_bookings
  SET status = 'confirmed',
      hold_expires_at = NULL,
      updated_at = now(),
      paystack_transaction_id = p_transaction_id,
      paid_amount_pesewas = p_amount_pesewas,
      paid_at = p_paid_at,
      payment_note = ''
  WHERE id = v_booking.id;

  RETURN 'confirmed';
END;
$$;

CREATE OR REPLACE FUNCTION mark_stay_payment_failed(p_reference text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE stay_bookings
  SET status = 'payment_failed',
      updated_at = now(),
      payment_note = 'The payment was not completed.'
  WHERE paystack_reference = p_reference AND status = 'pending_payment';
$$;

REVOKE EXECUTE ON FUNCTION stay_room_availability(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION stay_room_availability(date, date) TO anon, authenticated;

REVOKE EXECUTE ON FUNCTION create_stay_hold(uuid, date, date, integer, boolean, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_stay_hold(uuid, date, date, integer, boolean, text, text, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION prepare_stay_payment(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION prepare_stay_payment(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION confirm_stay_payment(text, bigint, integer, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION confirm_stay_payment(text, bigint, integer, text, timestamptz) TO service_role;

REVOKE EXECUTE ON FUNCTION mark_stay_payment_failed(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION mark_stay_payment_failed(text) TO service_role;

-- ===========================================================================
-- 11. STAY PAYSTACK ACCESS CODE COLUMN
-- ===========================================================================

ALTER TABLE stay_bookings ADD COLUMN IF NOT EXISTS paystack_access_code text;

-- ===========================================================================
-- 12. STAY CHECK-IN
-- ===========================================================================

ALTER TABLE stay_bookings ADD COLUMN IF NOT EXISTS checked_in_at timestamptz;

CREATE OR REPLACE FUNCTION admin_check_in_booking(p_booking_id uuid)
RETURNS stay_bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking stay_bookings;
BEGIN
  IF NOT is_edan_admin() THEN
    RAISE EXCEPTION 'You are not authorised to manage bookings.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_booking
  FROM stay_bookings
  WHERE id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'That booking does not exist.';
  END IF;

  IF v_booking.status <> 'confirmed' THEN
    RAISE EXCEPTION 'Only confirmed bookings can be checked in.';
  END IF;

  IF v_booking.checked_in_at IS NOT NULL THEN
    RAISE EXCEPTION 'This guest is already checked in.';
  END IF;

  IF v_booking.check_in > CURRENT_DATE THEN
    RAISE EXCEPTION 'Guests can be checked in from their arrival date.';
  END IF;

  UPDATE stay_bookings
  SET checked_in_at = now()
  WHERE id = p_booking_id
  RETURNING * INTO v_booking;

  RETURN v_booking;
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_check_in_booking(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_check_in_booking(uuid) TO authenticated;

-- ===========================================================================
-- 13. STAY CONFIRMATION LOOKUP
-- ===========================================================================

CREATE OR REPLACE FUNCTION get_own_stay_confirmation(p_booking_id uuid)
RETURNS TABLE (
  booking_reference text,
  status text,
  room_name text,
  guest_name text,
  guest_email text,
  check_in date,
  check_out date,
  guests smallint,
  breakfast_included boolean,
  nightly_rate_ghs integer,
  total_ghs integer,
  paid_amount_pesewas integer,
  paid_at timestamptz,
  paystack_reference text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    b.booking_reference,
    b.status,
    r.name,
    b.guest_name,
    b.guest_email,
    b.check_in,
    b.check_out,
    b.guests,
    b.breakfast_included,
    b.nightly_rate_ghs,
    b.total_ghs,
    b.paid_amount_pesewas,
    b.paid_at,
    b.paystack_reference
  FROM stay_bookings b
  JOIN stay_rooms r ON r.id = b.room_id
  WHERE b.id = p_booking_id
    AND b.user_id = auth.uid();
$$;

REVOKE EXECUTE ON FUNCTION get_own_stay_confirmation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION get_own_stay_confirmation(uuid) TO authenticated;

-- ===========================================================================
-- 14. MEMBERS COMMUNITY, GATHERINGS, BONUS VIDEOS
-- ===========================================================================

CREATE OR REPLACE FUNCTION is_active_member(tiers text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM memberships m
    WHERE m.user_id = auth.uid()
      AND m.membership_status = 'active'
      AND m.membership_tier = ANY (tiers)
      AND (m.expires_at IS NULL OR m.expires_at > now())
  );
$$;

REVOKE EXECUTE ON FUNCTION is_active_member(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION is_active_member(text[]) TO authenticated;

CREATE TABLE IF NOT EXISTS member_chat_profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username text NOT NULL UNIQUE CHECK (username ~ '^[A-Za-z0-9_]{3,24}$'),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE member_chat_profiles ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON member_chat_profiles TO authenticated;

DROP POLICY IF EXISTS "active_members_select_chat_profiles" ON member_chat_profiles;
CREATE POLICY "active_members_select_chat_profiles" ON member_chat_profiles FOR SELECT
  TO authenticated USING (is_active_member(ARRAY['monthly', 'annual']));

DROP POLICY IF EXISTS "active_members_insert_chat_profiles" ON member_chat_profiles;
CREATE POLICY "active_members_insert_chat_profiles" ON member_chat_profiles FOR INSERT
  TO authenticated WITH CHECK (
    user_id = auth.uid() AND is_active_member(ARRAY['monthly', 'annual'])
  );

DROP POLICY IF EXISTS "active_members_update_chat_profiles" ON member_chat_profiles;
CREATE POLICY "active_members_update_chat_profiles" ON member_chat_profiles FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid() AND is_active_member(ARRAY['monthly', 'annual']))
  WITH CHECK (user_id = auth.uid() AND is_active_member(ARRAY['monthly', 'annual']));

CREATE TABLE IF NOT EXISTS member_chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  message text NOT NULL CHECK (length(btrim(message)) BETWEEN 1 AND 1000),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS member_chat_messages_created_at_idx
  ON member_chat_messages (created_at DESC);

ALTER TABLE member_chat_messages ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT ON member_chat_messages TO authenticated;

DROP POLICY IF EXISTS "active_members_select_chat_messages" ON member_chat_messages;
CREATE POLICY "active_members_select_chat_messages" ON member_chat_messages FOR SELECT
  TO authenticated USING (is_active_member(ARRAY['monthly', 'annual']));

DROP POLICY IF EXISTS "active_members_insert_chat_messages" ON member_chat_messages;
CREATE POLICY "active_members_insert_chat_messages" ON member_chat_messages FOR INSERT
  TO authenticated WITH CHECK (
    user_id = auth.uid()
    AND is_active_member(ARRAY['monthly', 'annual'])
    AND EXISTS (SELECT 1 FROM member_chat_profiles p WHERE p.user_id = auth.uid())
  );

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'member_chat_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE member_chat_messages;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS member_gatherings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
  description text NOT NULL DEFAULT '',
  starts_at timestamptz,
  location text NOT NULL DEFAULT '',
  image_path text NOT NULL DEFAULT '',
  registration_url text NOT NULL DEFAULT '',
  is_published boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE member_gatherings ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON member_gatherings TO authenticated;

DROP POLICY IF EXISTS "members_select_published_gatherings" ON member_gatherings;
CREATE POLICY "members_select_published_gatherings" ON member_gatherings FOR SELECT
  TO authenticated USING (
    (is_published AND is_active_member(ARRAY['monthly', 'annual'])) OR is_edan_admin()
  );

DROP POLICY IF EXISTS "admins_insert_gatherings" ON member_gatherings;
CREATE POLICY "admins_insert_gatherings" ON member_gatherings FOR INSERT
  TO authenticated WITH CHECK (is_edan_admin());

DROP POLICY IF EXISTS "admins_update_gatherings" ON member_gatherings;
CREATE POLICY "admins_update_gatherings" ON member_gatherings FOR UPDATE
  TO authenticated USING (is_edan_admin()) WITH CHECK (is_edan_admin());

DROP POLICY IF EXISTS "admins_delete_gatherings" ON member_gatherings;
CREATE POLICY "admins_delete_gatherings" ON member_gatherings FOR DELETE
  TO authenticated USING (is_edan_admin());

CREATE TABLE IF NOT EXISTS member_bonus_videos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
  description text NOT NULL DEFAULT '',
  video_path text NOT NULL DEFAULT '',
  poster_path text NOT NULL DEFAULT '',
  is_published boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE member_bonus_videos ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON member_bonus_videos TO authenticated;

DROP POLICY IF EXISTS "annual_members_select_published_bonus_videos" ON member_bonus_videos;
CREATE POLICY "annual_members_select_published_bonus_videos" ON member_bonus_videos FOR SELECT
  TO authenticated USING (
    (is_published AND is_active_member(ARRAY['annual'])) OR is_edan_admin()
  );

DROP POLICY IF EXISTS "admins_insert_bonus_videos" ON member_bonus_videos;
CREATE POLICY "admins_insert_bonus_videos" ON member_bonus_videos FOR INSERT
  TO authenticated WITH CHECK (is_edan_admin());

DROP POLICY IF EXISTS "admins_update_bonus_videos" ON member_bonus_videos;
CREATE POLICY "admins_update_bonus_videos" ON member_bonus_videos FOR UPDATE
  TO authenticated USING (is_edan_admin()) WITH CHECK (is_edan_admin());

DROP POLICY IF EXISTS "admins_delete_bonus_videos" ON member_bonus_videos;
CREATE POLICY "admins_delete_bonus_videos" ON member_bonus_videos FOR DELETE
  TO authenticated USING (is_edan_admin());

-- ===========================================================================
-- 15. MEMBERSHIP INTEREST FORM FIELDS + SUBMIT FUNCTION
-- ===========================================================================

ALTER TABLE membership_applications
  ADD COLUMN IF NOT EXISTS full_name text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS practice_type text CHECK (practice_type IN ('researcher', 'creative', 'spatial_practitioner', 'collective', 'student', 'partner_institution', 'other')),
  ADD COLUMN IF NOT EXISTS based_in text CHECK (based_in IN ('accra', 'passing_through')),
  ADD COLUMN IF NOT EXISTS about_work text CHECK (char_length(about_work) <= 1000),
  ADD COLUMN IF NOT EXISTS commitment_agreed boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS submitted_at timestamptz;

CREATE OR REPLACE FUNCTION submit_membership_interest(
  p_full_name text,
  p_phone text,
  p_practice_type text,
  p_based_in text,
  p_about_work text,
  p_commitment_agreed boolean
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $
DECLARE
  v_user uuid := auth.uid();
  v_email text := auth.jwt() ->> 'email';
  v_id uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Please sign in first' USING ERRCODE = '42501';
  END IF;

  IF char_length(btrim(coalesce(p_full_name, ''))) = 0 OR char_length(p_full_name) > 100 THEN
    RAISE EXCEPTION 'Please enter your full name';
  END IF;

  IF char_length(btrim(coalesce(p_phone, ''))) = 0 OR char_length(p_phone) > 20 THEN
    RAISE EXCEPTION 'Please enter a valid phone number';
  END IF;

  IF p_practice_type IS NULL OR p_practice_type NOT IN ('researcher', 'creative', 'spatial_practitioner', 'collective', 'student', 'partner_institution', 'other') THEN
    RAISE EXCEPTION 'Choose what best describes you';
  END IF;

  IF p_based_in IS NULL OR p_based_in NOT IN ('accra', 'passing_through') THEN
    RAISE EXCEPTION 'Tell us where you are based';
  END IF;

  IF char_length(btrim(coalesce(p_about_work, ''))) = 0 OR char_length(p_about_work) > 1000 THEN
    RAISE EXCEPTION 'Tell us about your work (up to 1000 characters)';
  END IF;

  IF p_commitment_agreed IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Please agree to the shared commitment to a fairer city';
  END IF;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'Your account has no email address';
  END IF;

  SELECT id INTO v_id
  FROM membership_applications
  WHERE user_id = v_user AND status = 'pending'
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_id IS NULL THEN
    INSERT INTO membership_applications (
      user_id, applicant_email, status, full_name, phone, practice_type,
      based_in, about_work, commitment_agreed, submitted_at
    )
    VALUES (
      v_user, v_email, 'pending', btrim(p_full_name), btrim(p_phone), p_practice_type,
      p_based_in, btrim(p_about_work), true, now()
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE membership_applications
    SET full_name = btrim(p_full_name),
        phone = btrim(p_phone),
        practice_type = p_practice_type,
        based_in = p_based_in,
        about_work = btrim(p_about_work),
        commitment_agreed = true,
        submitted_at = now()
    WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$;

REVOKE EXECUTE ON FUNCTION submit_membership_interest(text, text, text, text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION submit_membership_interest(text, text, text, text, text, boolean) TO authenticated;

-- ===========================================================================
-- 16. ADMIN DASHBOARD MEMBERSHIP STATS
-- ===========================================================================

CREATE OR REPLACE FUNCTION admin_dashboard_kpis()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $
BEGIN
  IF NOT is_edan_admin() THEN
    RAISE EXCEPTION 'Admins only' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'active_members', (
      SELECT count(*)::int FROM memberships
      WHERE membership_status = 'active' AND (expires_at IS NULL OR expires_at > now())
    ),
    'pending_review', (
      SELECT count(*)::int FROM membership_applications
      WHERE status = 'pending' AND submitted_at IS NOT NULL
    ),
    'paid_awaiting_activation', (
      SELECT count(*)::int FROM payment_transactions pt
      JOIN membership_applications ma ON ma.id = pt.membership_application_id
      WHERE pt.status = 'success' AND ma.status = 'pending'
    ),
    'expired', (
      SELECT count(*)::int FROM memberships
      WHERE membership_status = 'expired'
         OR (membership_status = 'active' AND expires_at IS NOT NULL AND expires_at <= now())
    )
  );
END;
$;

REVOKE EXECUTE ON FUNCTION admin_dashboard_kpis() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_dashboard_kpis() TO authenticated;

-- ===========================================================================
-- 17. ADMIN DELETE POLICIES, SITE-IMAGES BUCKET, ROOM PHOTOS
-- ===========================================================================

DROP POLICY IF EXISTS "admins_delete_stay_bookings" ON public.stay_bookings;
CREATE POLICY "admins_delete_stay_bookings" ON public.stay_bookings FOR DELETE
TO authenticated
USING (
  public.is_edan_admin()
  AND status IN ('pending_payment', 'payment_failed', 'cancelled')
);

DROP POLICY IF EXISTS "admins_delete_stay_rooms" ON public.stay_rooms;
CREATE POLICY "admins_delete_stay_rooms" ON public.stay_rooms FOR DELETE
TO authenticated
USING (public.is_edan_admin());

DROP POLICY IF EXISTS "admins_delete_membership_applications" ON public.membership_applications;
CREATE POLICY "admins_delete_membership_applications" ON public.membership_applications FOR DELETE
TO authenticated
USING (
  public.is_edan_admin()
  AND status IN ('pending', 'rejected')
);

ALTER TABLE public.stay_rooms ADD COLUMN IF NOT EXISTS image_path text NOT NULL DEFAULT '';
ALTER TABLE public.membership_applications ADD COLUMN IF NOT EXISTS submission_emailed_at timestamptz;
ALTER TABLE public.stay_bookings ADD COLUMN IF NOT EXISTS confirmation_emailed_at timestamptz;
GRANT UPDATE (image_path) ON public.stay_rooms TO authenticated;
GRANT DELETE ON public.stay_bookings, public.stay_rooms, public.membership_applications TO authenticated;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'site-images',
  'site-images',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/gif']
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "admins_insert_site_images" ON storage.objects;
CREATE POLICY "admins_insert_site_images" ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'site-images' AND public.is_edan_admin());

DROP POLICY IF EXISTS "admins_update_site_images" ON storage.objects;
CREATE POLICY "admins_update_site_images" ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'site-images' AND public.is_edan_admin())
WITH CHECK (bucket_id = 'site-images' AND public.is_edan_admin());

DROP POLICY IF EXISTS "admins_delete_site_images" ON storage.objects;
CREATE POLICY "admins_delete_site_images" ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'site-images' AND public.is_edan_admin());

-- ===========================================================================
-- 18. SAMPLE ROOMS
-- ===========================================================================
-- These 5 rooms are needed for the Stay booking page to work.
-- Safe to re-run (ON CONFLICT does nothing).

INSERT INTO stay_rooms (name) VALUES ('001')
ON CONFLICT (name) DO NOTHING;
INSERT INTO stay_rooms (name) VALUES ('002')
ON CONFLICT (name) DO NOTHING;
INSERT INTO stay_rooms (name) VALUES ('003')
ON CONFLICT (name) DO NOTHING;
INSERT INTO stay_rooms (name) VALUES ('004')
ON CONFLICT (name) DO NOTHING;
INSERT INTO stay_rooms (name) VALUES ('005')
ON CONFLICT (name) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ===========================================================================
-- DONE. Your database is now fully set up.
-- ===========================================================================
-- AFTER RUNNING THIS SCRIPT, do one more thing to make yourself an admin:
--
-- 1. Sign up for an account on your website's login page first.
-- 2. Go to your Supabase dashboard > Authentication > Users.
-- 3. Copy your user ID (the long string under the "UID" column).
-- 4. Come back to the SQL Editor and run this (replace YOUR-USER-ID-HERE):
--
--    INSERT INTO admins (user_id) VALUES ('YOUR-USER-ID-HERE')
--    ON CONFLICT (user_id) DO NOTHING;
--
-- That gives you access to the admin Dashboard.
-- ===========================================================================
