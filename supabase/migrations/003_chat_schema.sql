-- =============================================================================
-- 003_chat_schema.sql — Group chat with AI agents
-- =============================================================================

-- Conversations (DMs and groups, each with an AI agent)
CREATE TABLE public.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type TEXT NOT NULL CHECK (type IN ('dm', 'group')),
    title TEXT,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    agent_config JSONB NOT NULL DEFAULT '{"autoRespond": false, "mentionOnly": true}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_message_at TIMESTAMPTZ,
    last_message_preview TEXT,
    is_archived BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX idx_conversations_updated ON public.conversations(updated_at DESC);
CREATE INDEX idx_conversations_last_message ON public.conversations(last_message_at DESC NULLS LAST);

-- =============================================================================
-- Conversation Participants
-- =============================================================================

CREATE TABLE public.conversation_participants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')) DEFAULT 'member',
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_read_at TIMESTAMPTZ,
    notifications_muted BOOLEAN NOT NULL DEFAULT false,
    is_active BOOLEAN NOT NULL DEFAULT true,
    UNIQUE(conversation_id, user_id)
);

CREATE INDEX idx_participants_user ON public.conversation_participants(user_id) WHERE is_active = true;
CREATE INDEX idx_participants_conversation ON public.conversation_participants(conversation_id) WHERE is_active = true;

-- =============================================================================
-- Messages
-- =============================================================================

CREATE TABLE public.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES public.profiles(id),  -- NULL = AI agent
    content TEXT NOT NULL,
    message_type TEXT NOT NULL CHECK (message_type IN ('text', 'ai_response', 'system', 'tool_result', 'tool_call')) DEFAULT 'text',
    metadata JSONB DEFAULT '{}',
    reply_to_id UUID REFERENCES public.messages(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    edited_at TIMESTAMPTZ
);

CREATE INDEX idx_messages_conversation ON public.messages(conversation_id, created_at DESC);
CREATE INDEX idx_messages_sender ON public.messages(sender_id);

-- =============================================================================
-- Tool Connections
-- =============================================================================

CREATE TABLE public.tool_connections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE SET NULL,
    tool_type TEXT NOT NULL CHECK (tool_type IN ('calendar', 'email', 'contacts', 'reminders', 'notes', 'custom')),
    provider TEXT NOT NULL,
    credentials_encrypted TEXT,
    scopes TEXT[] DEFAULT ARRAY['read'],
    is_active BOOLEAN NOT NULL DEFAULT true,
    connected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ,
    UNIQUE(user_id, tool_type, provider, conversation_id)
);

CREATE INDEX idx_tool_connections_user ON public.tool_connections(user_id) WHERE is_active = true;
CREATE INDEX idx_tool_connections_conversation ON public.tool_connections(conversation_id) WHERE is_active = true;

-- =============================================================================
-- Invitations & Referrals
-- =============================================================================

CREATE TABLE public.invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE CASCADE,
    inviter_id UUID NOT NULL REFERENCES public.profiles(id),
    invite_code TEXT UNIQUE NOT NULL,
    invite_type TEXT NOT NULL CHECK (invite_type IN ('chat', 'app')),
    max_uses INT DEFAULT 1,
    current_uses INT NOT NULL DEFAULT 0,
    credits_reward DOUBLE PRECISION NOT NULL DEFAULT 25.0,
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_invitations_code ON public.invitations(invite_code);
CREATE INDEX idx_invitations_inviter ON public.invitations(inviter_id);

CREATE TABLE public.invitation_redemptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invitation_id UUID NOT NULL REFERENCES public.invitations(id),
    redeemed_by UUID NOT NULL REFERENCES public.profiles(id),
    redeemed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(invitation_id, redeemed_by)
);

-- =============================================================================
-- Row Level Security
-- =============================================================================

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversation_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tool_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invitation_redemptions ENABLE ROW LEVEL SECURITY;

-- Conversations: only participants can see them
CREATE POLICY "Participants can view conversations"
    ON public.conversations FOR SELECT
    USING (id IN (
        SELECT conversation_id FROM public.conversation_participants
        WHERE user_id = auth.uid() AND is_active = true
    ));

CREATE POLICY "Authenticated users can create conversations"
    ON public.conversations FOR INSERT
    WITH CHECK (auth.uid() = created_by);

CREATE POLICY "Admins and owners can update conversations"
    ON public.conversations FOR UPDATE
    USING (id IN (
        SELECT conversation_id FROM public.conversation_participants
        WHERE user_id = auth.uid() AND role IN ('owner', 'admin') AND is_active = true
    ));

-- Participants: visible to fellow participants
CREATE POLICY "Participants can view fellow participants"
    ON public.conversation_participants FOR SELECT
    USING (conversation_id IN (
        SELECT cp.conversation_id FROM public.conversation_participants AS cp
        WHERE cp.user_id = auth.uid() AND cp.is_active = true
    ));

CREATE POLICY "Owners and admins can add participants"
    ON public.conversation_participants FOR INSERT
    WITH CHECK (
        conversation_id IN (
            SELECT conversation_id FROM public.conversation_participants
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin') AND is_active = true
        )
        OR user_id = auth.uid()
    );

CREATE POLICY "Users can update their own participation"
    ON public.conversation_participants FOR UPDATE
    USING (user_id = auth.uid());

-- Messages: participants can read, senders can write
CREATE POLICY "Participants can view messages"
    ON public.messages FOR SELECT
    USING (conversation_id IN (
        SELECT conversation_id FROM public.conversation_participants
        WHERE user_id = auth.uid() AND is_active = true
    ));

CREATE POLICY "Participants can send messages"
    ON public.messages FOR INSERT
    WITH CHECK (
        conversation_id IN (
            SELECT conversation_id FROM public.conversation_participants
            WHERE user_id = auth.uid() AND is_active = true
        )
        AND (sender_id = auth.uid() OR sender_id IS NULL)
    );

-- Tool connections: only the owner can see their own
CREATE POLICY "Users manage their own tool connections"
    ON public.tool_connections FOR ALL
    USING (user_id = auth.uid());

-- Invitations: anyone authenticated can view by code, inviters manage their own
CREATE POLICY "Anyone can view invitations"
    ON public.invitations FOR SELECT
    USING (auth.role() = 'authenticated');

CREATE POLICY "Users can create invitations"
    ON public.invitations FOR INSERT
    WITH CHECK (inviter_id = auth.uid());

CREATE POLICY "Users can update their own invitations"
    ON public.invitations FOR UPDATE
    USING (inviter_id = auth.uid());

-- Redemptions: authenticated users can insert, view their own
CREATE POLICY "Users can redeem invitations"
    ON public.invitation_redemptions FOR INSERT
    WITH CHECK (redeemed_by = auth.uid());

CREATE POLICY "Users can view their redemptions"
    ON public.invitation_redemptions FOR SELECT
    USING (redeemed_by = auth.uid());

-- =============================================================================
-- Realtime — enable for messages and participants
-- =============================================================================

ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
ALTER PUBLICATION supabase_realtime ADD TABLE public.conversation_participants;

-- =============================================================================
-- RPC: Redeem invitation (atomic)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.redeem_invitation(p_invite_code TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_invitation public.invitations%ROWTYPE;
    v_conversation_id UUID;
BEGIN
    -- Lock the invitation row
    SELECT * INTO v_invitation FROM public.invitations
    WHERE invite_code = p_invite_code
      AND expires_at > now()
      AND current_uses < max_uses
    FOR UPDATE;

    IF v_invitation IS NULL THEN
        RAISE EXCEPTION 'Invalid or expired invitation';
    END IF;

    IF v_invitation.inviter_id = auth.uid() THEN
        RAISE EXCEPTION 'Cannot redeem your own invitation';
    END IF;

    -- Prevent double redemption
    IF EXISTS (
        SELECT 1 FROM public.invitation_redemptions
        WHERE invitation_id = v_invitation.id AND redeemed_by = auth.uid()
    ) THEN
        RAISE EXCEPTION 'Already redeemed';
    END IF;

    -- Record redemption
    INSERT INTO public.invitation_redemptions (invitation_id, redeemed_by)
    VALUES (v_invitation.id, auth.uid());

    UPDATE public.invitations
    SET current_uses = current_uses + 1
    WHERE id = v_invitation.id;

    -- If chat invite, add user as participant
    IF v_invitation.invite_type = 'chat' AND v_invitation.conversation_id IS NOT NULL THEN
        INSERT INTO public.conversation_participants (conversation_id, user_id, role)
        VALUES (v_invitation.conversation_id, auth.uid(), 'member')
        ON CONFLICT DO NOTHING;
        v_conversation_id := v_invitation.conversation_id;
    END IF;

    RETURN v_conversation_id;
END;
$$;

-- =============================================================================
-- RPC: Get tools available in a conversation (no credentials exposed)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_conversation_tools(p_conversation_id UUID)
RETURNS TABLE (tool_type TEXT, provider TEXT, scopes TEXT[], owner_display_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT tc.tool_type, tc.provider, tc.scopes, p.display_name
    FROM public.tool_connections tc
    JOIN public.profiles p ON p.id = tc.user_id
    JOIN public.conversation_participants cp
        ON cp.user_id = tc.user_id
        AND cp.conversation_id = p_conversation_id
        AND cp.is_active = true
    WHERE (tc.conversation_id = p_conversation_id OR tc.conversation_id IS NULL)
      AND tc.is_active = true;
END;
$$;

-- =============================================================================
-- Trigger: Update conversation.updated_at and last_message on new message
-- =============================================================================

CREATE OR REPLACE FUNCTION public.update_conversation_on_message()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE public.conversations
    SET updated_at = now(),
        last_message_at = NEW.created_at,
        last_message_preview = LEFT(NEW.content, 100)
    WHERE id = NEW.conversation_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_update_conversation_on_message
    AFTER INSERT ON public.messages
    FOR EACH ROW
    EXECUTE FUNCTION public.update_conversation_on_message();
