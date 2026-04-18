-- TealeSDK schema: third-party app resource contribution
-- Tracks SDK app registrations, credit balances, and earning reports

-- SDK app registration
CREATE TABLE sdk_apps (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_id TEXT UNIQUE NOT NULL,
    developer_user_id UUID REFERENCES profiles(id),
    developer_wallet_id TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    is_active BOOLEAN DEFAULT TRUE
);

-- Server-side credit balances per app+device (authoritative for transfers)
CREATE TABLE sdk_credit_balances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_id TEXT REFERENCES sdk_apps(app_id),
    device_id UUID REFERENCES devices(id),
    balance DOUBLE PRECISION DEFAULT 0,
    total_earned DOUBLE PRECISION DEFAULT 0,
    total_transferred DOUBLE PRECISION DEFAULT 0,
    last_updated TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(app_id, device_id)
);

-- Credit earning reports (devices report completed inference work)
CREATE TABLE credit_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID REFERENCES devices(id),
    app_id TEXT REFERENCES sdk_apps(app_id),
    tokens_generated INTEGER NOT NULL,
    model_id TEXT NOT NULL,
    credits_earned DOUBLE PRECISION NOT NULL,
    peer_node_id TEXT,
    request_id UUID UNIQUE,
    reported_at TIMESTAMPTZ DEFAULT NOW(),
    verified BOOLEAN DEFAULT FALSE
);

-- Add SDK fields to existing devices table
ALTER TABLE devices ADD COLUMN IF NOT EXISTS sdk_app_id TEXT REFERENCES sdk_apps(app_id);
ALTER TABLE devices ADD COLUMN IF NOT EXISTS is_sdk_contributor BOOLEAN DEFAULT FALSE;

-- RLS policies
ALTER TABLE sdk_apps ENABLE ROW LEVEL SECURITY;
ALTER TABLE sdk_credit_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_reports ENABLE ROW LEVEL SECURITY;

-- SDK apps: developers can read their own apps
CREATE POLICY "Users can view their own SDK apps"
    ON sdk_apps FOR SELECT
    USING (developer_user_id = auth.uid());

CREATE POLICY "Users can create SDK apps"
    ON sdk_apps FOR INSERT
    WITH CHECK (developer_user_id = auth.uid());

-- Credit balances: readable by the app's developer
CREATE POLICY "Developers can view their app credit balances"
    ON sdk_credit_balances FOR SELECT
    USING (app_id IN (SELECT app_id FROM sdk_apps WHERE developer_user_id = auth.uid()));

-- Credit reports: devices can insert, developers can read
CREATE POLICY "Devices can report earnings"
    ON credit_reports FOR INSERT
    WITH CHECK (true);

CREATE POLICY "Developers can view their app credit reports"
    ON credit_reports FOR SELECT
    USING (app_id IN (SELECT app_id FROM sdk_apps WHERE developer_user_id = auth.uid()));

-- Index for efficient queries
CREATE INDEX idx_credit_reports_app_id ON credit_reports(app_id);
CREATE INDEX idx_credit_reports_device_id ON credit_reports(device_id);
CREATE INDEX idx_sdk_credit_balances_app_id ON sdk_credit_balances(app_id);
