-- Teale Auth Schema
-- Run this in your Supabase SQL Editor or via supabase db push

-- =============================================================================
-- PROFILES
-- =============================================================================

CREATE TABLE public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name TEXT,
    phone TEXT,
    email TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Users can read any profile (needed for device transfer recipient lookup)
CREATE POLICY "Authenticated users can view profiles"
    ON public.profiles FOR SELECT
    USING (auth.role() = 'authenticated');

CREATE POLICY "Users can insert their own profile"
    ON public.profiles FOR INSERT
    WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can update their own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id);

-- =============================================================================
-- DEVICES
-- =============================================================================

CREATE TABLE public.devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    device_name TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('macos', 'ios')),
    chip_name TEXT,
    ram_gb INT,
    wan_node_id TEXT,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_active BOOLEAN NOT NULL DEFAULT true
);

CREATE INDEX idx_devices_user_id ON public.devices(user_id);
CREATE INDEX idx_devices_wan_node_id ON public.devices(wan_node_id);

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own devices"
    ON public.devices FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own devices"
    ON public.devices FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own devices"
    ON public.devices FOR UPDATE
    USING (auth.uid() = user_id);

-- =============================================================================
-- DEVICE TRANSFERS
-- =============================================================================

CREATE TABLE public.device_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL REFERENCES public.devices(id),
    from_user_id UUID NOT NULL REFERENCES public.profiles(id),
    to_user_id UUID NOT NULL REFERENCES public.profiles(id),
    transferred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.device_transfers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view transfers they were part of"
    ON public.device_transfers FOR SELECT
    USING (auth.uid() = from_user_id OR auth.uid() = to_user_id);

CREATE POLICY "Users can create transfers from their devices"
    ON public.device_transfers FOR INSERT
    WITH CHECK (auth.uid() = from_user_id);

-- =============================================================================
-- ATOMIC DEVICE TRANSFER FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION transfer_device(
    p_device_id UUID,
    p_to_user_id UUID,
    p_credits_at_transfer DOUBLE PRECISION DEFAULT 0
) RETURNS void AS $$
DECLARE
    v_from_user_id UUID;
BEGIN
    -- Verify caller owns the device
    SELECT user_id INTO v_from_user_id
    FROM public.devices
    WHERE id = p_device_id AND user_id = auth.uid() AND is_active = true;

    IF v_from_user_id IS NULL THEN
        RAISE EXCEPTION 'Device not found or not owned by caller';
    END IF;

    -- Verify recipient exists
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_to_user_id) THEN
        RAISE EXCEPTION 'Recipient not found';
    END IF;

    -- Create transfer record
    INSERT INTO public.device_transfers (device_id, from_user_id, to_user_id)
    VALUES (p_device_id, v_from_user_id, p_to_user_id);

    -- Update device ownership
    UPDATE public.devices
    SET user_id = p_to_user_id, last_seen = now()
    WHERE id = p_device_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- AUTO-UPDATE updated_at ON PROFILES
-- =============================================================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();
