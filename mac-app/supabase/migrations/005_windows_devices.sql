-- Allow Windows Teale companion installs to register into the shared devices table.

ALTER TABLE public.devices
    DROP CONSTRAINT IF EXISTS devices_platform_check;

ALTER TABLE public.devices
    ADD CONSTRAINT devices_platform_check
    CHECK (platform IN ('macos', 'ios', 'windows'));
