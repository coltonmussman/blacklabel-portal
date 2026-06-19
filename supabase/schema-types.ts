export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      ad_spend: {
        Row: {
          amount_cents: number
          created_at: string
          id: string
          notes: string | null
          platform: string
          source: string
          spend_date: string
          vertical: string | null
        }
        Insert: {
          amount_cents: number
          created_at?: string
          id?: string
          notes?: string | null
          platform?: string
          source?: string
          spend_date?: string
          vertical?: string | null
        }
        Update: {
          amount_cents?: number
          created_at?: string
          id?: string
          notes?: string | null
          platform?: string
          source?: string
          spend_date?: string
          vertical?: string | null
        }
        Relationships: []
      }
      agent_profiles: {
        Row: {
          active_states: string | null
          active_verticals: string | null
          agent_tz: string
          billing_started_at: string | null
          cell_phone: string | null
          created_at: string
          current_period_end: string | null
          drop_days: number[]
          first_drop_at: string | null
          first_name: string | null
          id: string
          last_assigned_at: string | null
          last_name: string | null
          monthly_goal: number | null
          npn: string | null
          phone_verified_at: string | null
          received_this_week: number
          referral_code: string
          referred_by: string | null
          setup_complete: boolean
          setup_step: number
          sms_opt_in: boolean
          states_licensed: string | null
          status: string
          stripe_customer_id: string | null
          stripe_subscription_id: string | null
          subscription_status: string
          tier: string
          verticals: string | null
          weekly_cap: number
          weekly_investment: number | null
        }
        Insert: {
          active_states?: string | null
          active_verticals?: string | null
          agent_tz?: string
          billing_started_at?: string | null
          cell_phone?: string | null
          created_at?: string
          current_period_end?: string | null
          drop_days?: number[]
          first_drop_at?: string | null
          first_name?: string | null
          id: string
          last_assigned_at?: string | null
          last_name?: string | null
          monthly_goal?: number | null
          npn?: string | null
          phone_verified_at?: string | null
          received_this_week?: number
          referral_code: string
          referred_by?: string | null
          setup_complete?: boolean
          setup_step?: number
          sms_opt_in?: boolean
          states_licensed?: string | null
          status?: string
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          subscription_status?: string
          tier?: string
          verticals?: string | null
          weekly_cap?: number
          weekly_investment?: number | null
        }
        Update: {
          active_states?: string | null
          active_verticals?: string | null
          agent_tz?: string
          billing_started_at?: string | null
          cell_phone?: string | null
          created_at?: string
          current_period_end?: string | null
          drop_days?: number[]
          first_drop_at?: string | null
          first_name?: string | null
          id?: string
          last_assigned_at?: string | null
          last_name?: string | null
          monthly_goal?: number | null
          npn?: string | null
          phone_verified_at?: string | null
          received_this_week?: number
          referral_code?: string
          referred_by?: string | null
          setup_complete?: boolean
          setup_step?: number
          sms_opt_in?: boolean
          states_licensed?: string | null
          status?: string
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          subscription_status?: string
          tier?: string
          verticals?: string | null
          weekly_cap?: number
          weekly_investment?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "agent_profiles_referred_by_fkey"
            columns: ["referred_by"]
            isOneToOne: false
            referencedRelation: "agent_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      agent_waitlist: {
        Row: {
          created_at: string
          email: string
          first_name: string
          id: string
          last_name: string
          npn: string | null
          phone: string
          referral_code_used: string | null
          source: string | null
          states_licensed: string
          tier_interest: string | null
          utm_campaign: string | null
          utm_content: string | null
          utm_medium: string | null
          utm_source: string | null
          utm_term: string | null
          verticals: string | null
          weekly_lead_budget: string | null
        }
        Insert: {
          created_at?: string
          email: string
          first_name: string
          id?: string
          last_name: string
          npn?: string | null
          phone: string
          referral_code_used?: string | null
          source?: string | null
          states_licensed: string
          tier_interest?: string | null
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
          verticals?: string | null
          weekly_lead_budget?: string | null
        }
        Update: {
          created_at?: string
          email?: string
          first_name?: string
          id?: string
          last_name?: string
          npn?: string | null
          phone?: string
          referral_code_used?: string | null
          source?: string | null
          states_licensed?: string
          tier_interest?: string | null
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
          verticals?: string | null
          weekly_lead_budget?: string | null
        }
        Relationships: []
      }
      bl_action_log: {
        Row: {
          action: string
          at: string
          detail: Json | null
          id: string
        }
        Insert: {
          action: string
          at?: string
          detail?: Json | null
          id?: string
        }
        Update: {
          action?: string
          at?: string
          detail?: Json | null
          id?: string
        }
        Relationships: []
      }
      bl_alerts: {
        Row: {
          agent_id: string | null
          auto_action: string | null
          created_at: string
          detail: Json | null
          id: string
          resolved: boolean
          resolved_at: string | null
          severity: string
          subject: string
          type: string
        }
        Insert: {
          agent_id?: string | null
          auto_action?: string | null
          created_at?: string
          detail?: Json | null
          id?: string
          resolved?: boolean
          resolved_at?: string | null
          severity?: string
          subject: string
          type: string
        }
        Update: {
          agent_id?: string | null
          auto_action?: string | null
          created_at?: string
          detail?: Json | null
          id?: string
          resolved?: boolean
          resolved_at?: string | null
          severity?: string
          subject?: string
          type?: string
        }
        Relationships: [
          {
            foreignKeyName: "bl_alerts_agent_id_fkey"
            columns: ["agent_id"]
            isOneToOne: false
            referencedRelation: "agent_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      bl_config: {
        Row: {
          key: string
          updated_at: string
          value: string | null
        }
        Insert: {
          key: string
          updated_at?: string
          value?: string | null
        }
        Update: {
          key?: string
          updated_at?: string
          value?: string | null
        }
        Relationships: []
      }
      bl_rate_limit: {
        Row: {
          hits: number
          ip: string
          window_start: string
        }
        Insert: {
          hits?: number
          ip: string
          window_start?: string
        }
        Update: {
          hits?: number
          ip?: string
          window_start?: string
        }
        Relationships: []
      }
      coverage_changes: {
        Row: {
          agent_id: string
          applied: boolean
          change_type: string
          created_at: string
          effective_at: string
          id: string
          value: string
        }
        Insert: {
          agent_id: string
          applied?: boolean
          change_type: string
          created_at?: string
          effective_at: string
          id?: string
          value: string
        }
        Update: {
          agent_id?: string
          applied?: boolean
          change_type?: string
          created_at?: string
          effective_at?: string
          id?: string
          value?: string
        }
        Relationships: []
      }
      leads: {
        Row: {
          age: number | null
          aged_out_at: string | null
          agent_notes: string | null
          annual_premium: number | null
          assigned_agent_id: string | null
          assigned_at: string | null
          best_time: string | null
          consent_given: boolean
          consent_text: string | null
          coverage_amount: string | null
          created_at: string
          email: string | null
          first_name: string
          id: string
          income_band: string | null
          intent: string | null
          ip_address: string | null
          last_name: string
          lead_status: string
          monthly_income: string | null
          phone: string
          refund_reason: string | null
          refund_requested: boolean
          refund_requested_at: string | null
          refund_resolution: string | null
          refund_resolved_at: string | null
          sold_at: string | null
          source: string | null
          state: string
          status: string
          submitted_at: string | null
          tobacco: string | null
          trustedform_cert_url: string | null
          user_agent: string | null
          utm_campaign: string | null
          utm_content: string | null
          utm_medium: string | null
          utm_source: string | null
          utm_term: string | null
          vertical: string
        }
        Insert: {
          age?: number | null
          aged_out_at?: string | null
          agent_notes?: string | null
          annual_premium?: number | null
          assigned_agent_id?: string | null
          assigned_at?: string | null
          best_time?: string | null
          consent_given?: boolean
          consent_text?: string | null
          coverage_amount?: string | null
          created_at?: string
          email?: string | null
          first_name: string
          id?: string
          income_band?: string | null
          intent?: string | null
          ip_address?: string | null
          last_name: string
          lead_status?: string
          monthly_income?: string | null
          phone: string
          refund_reason?: string | null
          refund_requested?: boolean
          refund_requested_at?: string | null
          refund_resolution?: string | null
          refund_resolved_at?: string | null
          sold_at?: string | null
          source?: string | null
          state: string
          status?: string
          submitted_at?: string | null
          tobacco?: string | null
          trustedform_cert_url?: string | null
          user_agent?: string | null
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
          vertical?: string
        }
        Update: {
          age?: number | null
          aged_out_at?: string | null
          agent_notes?: string | null
          annual_premium?: number | null
          assigned_agent_id?: string | null
          assigned_at?: string | null
          best_time?: string | null
          consent_given?: boolean
          consent_text?: string | null
          coverage_amount?: string | null
          created_at?: string
          email?: string | null
          first_name?: string
          id?: string
          income_band?: string | null
          intent?: string | null
          ip_address?: string | null
          last_name?: string
          lead_status?: string
          monthly_income?: string | null
          phone?: string
          refund_reason?: string | null
          refund_requested?: boolean
          refund_requested_at?: string | null
          refund_resolution?: string | null
          refund_resolved_at?: string | null
          sold_at?: string | null
          source?: string | null
          state?: string
          status?: string
          submitted_at?: string | null
          tobacco?: string | null
          trustedform_cert_url?: string | null
          user_agent?: string | null
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
          vertical?: string
        }
        Relationships: [
          {
            foreignKeyName: "leads_assigned_agent_id_fkey"
            columns: ["assigned_agent_id"]
            isOneToOne: false
            referencedRelation: "agent_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      markets: {
        Row: {
          is_open: boolean
          notes: string | null
          opened_at: string | null
          state: string
          updated_at: string
          vertical: string
        }
        Insert: {
          is_open?: boolean
          notes?: string | null
          opened_at?: string | null
          state: string
          updated_at?: string
          vertical: string
        }
        Update: {
          is_open?: boolean
          notes?: string | null
          opened_at?: string | null
          state?: string
          updated_at?: string
          vertical?: string
        }
        Relationships: []
      }
      referrals: {
        Row: {
          created_at: string
          id: string
          qualified_at: string | null
          referral_code_used: string | null
          referred_agent_id: string
          referrer_agent_id: string
          signed_up_at: string
          status: string
          welcome_discount_applied: boolean
        }
        Insert: {
          created_at?: string
          id?: string
          qualified_at?: string | null
          referral_code_used?: string | null
          referred_agent_id: string
          referrer_agent_id: string
          signed_up_at?: string
          status?: string
          welcome_discount_applied?: boolean
        }
        Update: {
          created_at?: string
          id?: string
          qualified_at?: string | null
          referral_code_used?: string | null
          referred_agent_id?: string
          referrer_agent_id?: string
          signed_up_at?: string
          status?: string
          welcome_discount_applied?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "referrals_referred_agent_id_fkey"
            columns: ["referred_agent_id"]
            isOneToOne: true
            referencedRelation: "agent_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "referrals_referrer_agent_id_fkey"
            columns: ["referrer_agent_id"]
            isOneToOne: false
            referencedRelation: "agent_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      reward_ledger: {
        Row: {
          amount: number
          beneficiary_agent_id: string
          created_at: string
          entry_type: string
          id: string
          period_week: string | null
          referral_id: string
          stripe_ref: string | null
        }
        Insert: {
          amount: number
          beneficiary_agent_id: string
          created_at?: string
          entry_type: string
          id?: string
          period_week?: string | null
          referral_id: string
          stripe_ref?: string | null
        }
        Update: {
          amount?: number
          beneficiary_agent_id?: string
          created_at?: string
          entry_type?: string
          id?: string
          period_week?: string | null
          referral_id?: string
          stripe_ref?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "reward_ledger_beneficiary_agent_id_fkey"
            columns: ["beneficiary_agent_id"]
            isOneToOne: false
            referencedRelation: "agent_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reward_ledger_referral_id_fkey"
            columns: ["referral_id"]
            isOneToOne: false
            referencedRelation: "referrals"
            referencedColumns: ["id"]
          },
        ]
      }
      support_requests: {
        Row: {
          agent_email: string | null
          agent_id: string | null
          created_at: string
          id: string
          message: string
          resolved: boolean
          topic: string | null
        }
        Insert: {
          agent_email?: string | null
          agent_id?: string | null
          created_at?: string
          id?: string
          message: string
          resolved?: boolean
          topic?: string | null
        }
        Update: {
          agent_email?: string | null
          agent_id?: string | null
          created_at?: string
          id?: string
          message?: string
          resolved?: boolean
          topic?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "support_requests_agent_id_fkey"
            columns: ["agent_id"]
            isOneToOne: false
            referencedRelation: "agent_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      vault_overview: {
        Row: {
          oldest: string | null
          oldest_age: string | null
          state: string | null
          vertical: string | null
          waiting: number | null
        }
        Relationships: []
      }
    }
    Functions: {
      bl_age_out_stale: { Args: never; Returns: number }
      bl_agent_pool_total: { Args: never; Returns: Json }
      bl_apply_billing: {
        Args: {
          p_customer: string
          p_period_end?: string
          p_status: string
          p_subscription: string
        }
        Returns: Json
      }
      bl_cancel_expansion: {
        Args: { p_change_type: string; p_value: string }
        Returns: Json
      }
      bl_cfg: { Args: { p_key: string }; Returns: string }
      bl_drain_vault_all: { Args: never; Returns: number }
      bl_drain_vault_for_agent: { Args: { p_agent: string }; Returns: number }
      bl_finish_setup: { Args: never; Returns: number }
      bl_gen_referral_code: { Args: never; Returns: string }
      bl_is_owner: { Args: never; Returns: boolean }
      bl_link_stripe_customer: {
        Args: {
          p_agent_id: string
          p_customer: string
          p_email: string
          p_period_end?: string
          p_status?: string
          p_subscription: string
        }
        Returns: Json
      }
      bl_local_isodow: { Args: { p_tz: string }; Returns: number }
      bl_my_referrals: { Args: never; Returns: Json }
      bl_norm_states: { Args: { s: string }; Returns: string[] }
      bl_owner_action_log: { Args: { p_limit?: number }; Returns: Json }
      bl_owner_add_ad_spend: {
        Args: {
          p_amount: number
          p_date?: string
          p_notes?: string
          p_platform?: string
          p_vertical?: string
        }
        Returns: undefined
      }
      bl_owner_agent_delivery: { Args: never; Returns: Json }
      bl_owner_agent_detail: { Args: { p_agent: string }; Returns: Json }
      bl_owner_agent_profit: { Args: never; Returns: Json }
      bl_owner_agents: { Args: never; Returns: Json }
      bl_owner_alert_summary: { Args: never; Returns: Json }
      bl_owner_alerts: {
        Args: { p_include_resolved?: boolean; p_limit?: number }
        Returns: Json
      }
      bl_owner_assign_leads: {
        Args: {
          p_agent: string
          p_count?: number
          p_state?: string
          p_vertical?: string
        }
        Returns: Json
      }
      bl_owner_billing_health: { Args: never; Returns: Json }
      bl_owner_business_pl: { Args: never; Returns: Json }
      bl_owner_delete_ad_spend: { Args: { p_id: string }; Returns: undefined }
      bl_owner_landing_performance: { Args: { p_days?: number }; Returns: Json }
      bl_owner_lead_flow: { Args: { p_days?: number }; Returns: Json }
      bl_owner_leads: { Args: { p_limit?: number }; Returns: Json }
      bl_owner_markets: { Args: never; Returns: Json }
      bl_owner_metrics: { Args: never; Returns: Json }
      bl_owner_profit: { Args: never; Returns: Json }
      bl_owner_quality: { Args: { p_days?: number }; Returns: Json }
      bl_owner_reassign_lead: {
        Args: { p_agent: string; p_lead: string }
        Returns: undefined
      }
      bl_owner_referrals: { Args: never; Returns: Json }
      bl_owner_refund_replace: {
        Args: { p_lead: string; p_resolution?: string }
        Returns: Json
      }
      bl_owner_refunds: { Args: never; Returns: Json }
      bl_owner_resolve_alert: { Args: { p_id: string }; Returns: undefined }
      bl_owner_resolve_refund: {
        Args: { p_lead: string; p_resolution: string }
        Returns: undefined
      }
      bl_owner_set_agent_cap: {
        Args: { p_agent: string; p_cap: number }
        Returns: undefined
      }
      bl_owner_set_agent_status: {
        Args: { p_agent: string; p_status: string }
        Returns: undefined
      }
      bl_owner_set_agent_tier: {
        Args: { p_agent: string; p_tier: string }
        Returns: undefined
      }
      bl_owner_set_market: {
        Args: {
          p_notes?: string
          p_open: boolean
          p_state: string
          p_vertical: string
        }
        Returns: Json
      }
      bl_owner_support: { Args: { p_limit?: number }; Returns: Json }
      bl_owner_vault: { Args: never; Returns: Json }
      bl_precheck_lead: {
        Args: { p_email: string; p_ip: string; p_phone: string }
        Returns: Json
      }
      bl_promote_coverage_changes: {
        Args: { p_agent?: string }
        Returns: number
      }
      bl_quality_flag: {
        Args: { p_email: string; p_phone: string }
        Returns: string
      }
      bl_raise_alert: {
        Args: {
          p_agent?: string
          p_auto?: string
          p_dedupe_hours?: number
          p_detail: Json
          p_severity: string
          p_subject: string
          p_type: string
        }
        Returns: boolean
      }
      bl_rate_check: {
        Args: { p_ip: string; p_max?: number }
        Returns: boolean
      }
      bl_referral_attribute: {
        Args: { p_code: string; p_email?: string; p_new_agent: string }
        Returns: undefined
      }
      bl_referral_disqualify: {
        Args: { p_agent: string; p_reason: string }
        Returns: undefined
      }
      bl_referral_eval_clawback: {
        Args: {
          p_invoice: string
          p_refunded_cents: number
          p_total_cents: number
        }
        Returns: Json
      }
      bl_referral_eval_payment: {
        Args: { p_amount_cents: number; p_customer: string; p_invoice: string }
        Returns: Json
      }
      bl_referral_mark_canceled_by_customer: {
        Args: { p_customer: string }
        Returns: undefined
      }
      bl_referral_mark_welcome: {
        Args: { p_agent: string }
        Returns: undefined
      }
      bl_referral_record_accrual: {
        Args: {
          p_amount_cents: number
          p_beneficiary: string
          p_friend_invoice: string
          p_period_week: string
          p_referral_id: string
        }
        Returns: boolean
      }
      bl_referral_record_clawback: {
        Args: {
          p_amount_cents: number
          p_beneficiary: string
          p_friend_invoice: string
          p_referral_id: string
        }
        Returns: boolean
      }
      bl_referral_welcome_eligibility: {
        Args: { p_agent: string }
        Returns: Json
      }
      bl_request_expansion: {
        Args: { p_change_type: string; p_value: string }
        Returns: Json
      }
      bl_retry_activations: { Args: never; Returns: number }
      bl_run_watchdog: { Args: never; Returns: Json }
      bl_send_agent_email: { Args: { p_lead_id: string }; Returns: undefined }
      bl_state_code: { Args: { s: string }; Returns: string }
      bl_tier_price: { Args: { t: string }; Returns: number }
      bl_vault_count: {
        Args: { p_state?: string; p_vertical?: string }
        Returns: number
      }
      bl_vert_label: { Args: { v: string }; Returns: string }
      reset_weekly_lead_counts: { Args: never; Returns: undefined }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
