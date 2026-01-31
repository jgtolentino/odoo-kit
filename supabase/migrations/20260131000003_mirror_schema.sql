-- ============================================================================
-- MIRROR SCHEMA: Read-Only Mirrors of Odoo Data
-- ============================================================================
-- Purpose: Supabase SSOT for state, config, and mirrors of Odoo SoR data
-- Pattern:
--   - Odoo = System of Record (writes, accounting truth)
--   - Supabase = SSOT for state, config, auth, telemetry, mirrors
--
-- CRITICAL: These tables are READ-ONLY mirrors. Never write to Odoo directly!
--   - Odoo → Supabase: cron / webhook / n8n (append-only or upsert)
--   - Supabase → Odoo: NEVER direct writes, always via Edge Function → Odoo API
--
-- This is exactly how Azure + SAP works internally.
-- ============================================================================

-- Create mirror schema for isolation
CREATE SCHEMA IF NOT EXISTS mirror;

-- Grant usage
GRANT USAGE ON SCHEMA mirror TO authenticated;
GRANT USAGE ON SCHEMA mirror TO service_role;

-- ============================================================================
-- ENUMS: Standardized Odoo types
-- ============================================================================

-- Partner type
CREATE TYPE mirror.partner_type AS ENUM (
  'contact',
  'invoice',
  'delivery',
  'other',
  'private'
);

-- Invoice state
CREATE TYPE mirror.invoice_state AS ENUM (
  'draft',
  'posted',
  'cancel'
);

-- Invoice type
CREATE TYPE mirror.move_type AS ENUM (
  'entry',
  'out_invoice',
  'out_refund',
  'in_invoice',
  'in_refund',
  'out_receipt',
  'in_receipt'
);

-- Order state
CREATE TYPE mirror.order_state AS ENUM (
  'draft',
  'sent',
  'sale',
  'done',
  'cancel'
);

-- Sync status
CREATE TYPE mirror.sync_status AS ENUM (
  'pending',
  'syncing',
  'synced',
  'failed',
  'stale'
);

-- ============================================================================
-- TABLE: mirror.sync_log
-- ============================================================================
-- Purpose: Track all sync operations from Odoo
-- ============================================================================

CREATE TABLE mirror.sync_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- What was synced
  table_name TEXT NOT NULL,
  operation TEXT NOT NULL,                    -- 'full', 'incremental', 'single'

  -- Results
  status mirror.sync_status NOT NULL DEFAULT 'pending',
  records_fetched INTEGER DEFAULT 0,
  records_created INTEGER DEFAULT 0,
  records_updated INTEGER DEFAULT 0,
  records_deleted INTEGER DEFAULT 0,

  -- Timing
  started_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  ended_at TIMESTAMPTZ,
  duration_ms INTEGER,

  -- Odoo context
  odoo_model TEXT,
  odoo_domain TEXT,
  odoo_last_write_date TIMESTAMPTZ,

  -- Error tracking
  error_message TEXT,
  error_details JSONB,

  -- Metadata
  metadata JSONB DEFAULT '{}',

  created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_sync_log_table ON mirror.sync_log(table_name);
CREATE INDEX idx_sync_log_started ON mirror.sync_log(started_at DESC);
CREATE INDEX idx_sync_log_status ON mirror.sync_log(status);

-- ============================================================================
-- TABLE: mirror.res_company
-- ============================================================================
-- Purpose: Mirror of Odoo companies (multi-company support)
-- ============================================================================

CREATE TABLE mirror.res_company (
  -- Primary key (matches Odoo ID)
  id INTEGER PRIMARY KEY,

  -- Core fields
  name TEXT NOT NULL,
  display_name TEXT,

  -- Identification
  vat TEXT,                                   -- Tax ID
  company_registry TEXT,                      -- Company registration number

  -- Address
  street TEXT,
  street2 TEXT,
  city TEXT,
  state_id INTEGER,
  zip TEXT,
  country_id INTEGER,

  -- Contact
  phone TEXT,
  mobile TEXT,
  email TEXT,
  website TEXT,

  -- Currency
  currency_id INTEGER,
  currency_code TEXT,

  -- Parent company (for multi-company hierarchies)
  parent_id INTEGER REFERENCES mirror.res_company(id),

  -- Metadata
  active BOOLEAN DEFAULT TRUE,

  -- Sync tracking
  odoo_write_date TIMESTAMPTZ,
  sync_status mirror.sync_status DEFAULT 'pending',
  last_synced_at TIMESTAMPTZ,

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_res_company_name ON mirror.res_company(name);
CREATE INDEX idx_res_company_active ON mirror.res_company(active) WHERE active = TRUE;

-- ============================================================================
-- TABLE: mirror.res_partner
-- ============================================================================
-- Purpose: Mirror of Odoo partners (customers, vendors, contacts)
-- ============================================================================

CREATE TABLE mirror.res_partner (
  -- Primary key (matches Odoo ID)
  id INTEGER PRIMARY KEY,

  -- Core fields
  name TEXT NOT NULL,
  display_name TEXT,

  -- Type and classification
  is_company BOOLEAN DEFAULT FALSE,
  type mirror.partner_type DEFAULT 'contact',

  -- Parent relationship
  parent_id INTEGER REFERENCES mirror.res_partner(id),
  company_id INTEGER REFERENCES mirror.res_company(id),

  -- Identification
  ref TEXT,                                   -- Internal reference
  vat TEXT,                                   -- Tax ID

  -- Address
  street TEXT,
  street2 TEXT,
  city TEXT,
  state_id INTEGER,
  zip TEXT,
  country_id INTEGER,
  country_code TEXT,

  -- Contact
  email TEXT,
  phone TEXT,
  mobile TEXT,
  website TEXT,

  -- Business classification
  customer_rank INTEGER DEFAULT 0,            -- Higher = more important customer
  supplier_rank INTEGER DEFAULT 0,            -- Higher = more important supplier

  -- Financial
  credit_limit DECIMAL(15, 2),

  -- Sales
  user_id INTEGER,                            -- Salesperson
  team_id INTEGER,                            -- Sales team

  -- Metadata
  active BOOLEAN DEFAULT TRUE,
  lang TEXT,
  tz TEXT,

  -- Tags (stored as Odoo category IDs)
  category_ids INTEGER[] DEFAULT '{}',

  -- Sync tracking
  odoo_write_date TIMESTAMPTZ,
  sync_status mirror.sync_status DEFAULT 'pending',
  last_synced_at TIMESTAMPTZ,

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes
CREATE INDEX idx_res_partner_name ON mirror.res_partner(name);
CREATE INDEX idx_res_partner_email ON mirror.res_partner(email) WHERE email IS NOT NULL;
CREATE INDEX idx_res_partner_ref ON mirror.res_partner(ref) WHERE ref IS NOT NULL;
CREATE INDEX idx_res_partner_vat ON mirror.res_partner(vat) WHERE vat IS NOT NULL;
CREATE INDEX idx_res_partner_company ON mirror.res_partner(company_id);
CREATE INDEX idx_res_partner_parent ON mirror.res_partner(parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX idx_res_partner_customer ON mirror.res_partner(customer_rank DESC) WHERE customer_rank > 0;
CREATE INDEX idx_res_partner_supplier ON mirror.res_partner(supplier_rank DESC) WHERE supplier_rank > 0;
CREATE INDEX idx_res_partner_active ON mirror.res_partner(active) WHERE active = TRUE;
CREATE INDEX idx_res_partner_sync ON mirror.res_partner(sync_status, last_synced_at);

-- ============================================================================
-- TABLE: mirror.account_move
-- ============================================================================
-- Purpose: Mirror of Odoo invoices and journal entries
-- ============================================================================

CREATE TABLE mirror.account_move (
  -- Primary key (matches Odoo ID)
  id INTEGER PRIMARY KEY,

  -- Core fields
  name TEXT NOT NULL,                         -- Invoice number
  ref TEXT,                                   -- External reference

  -- Type and state
  move_type mirror.move_type NOT NULL DEFAULT 'entry',
  state mirror.invoice_state NOT NULL DEFAULT 'draft',

  -- Relationships
  partner_id INTEGER REFERENCES mirror.res_partner(id),
  company_id INTEGER REFERENCES mirror.res_company(id),
  journal_id INTEGER,

  -- Dates
  date DATE NOT NULL,                         -- Accounting date
  invoice_date DATE,                          -- Invoice date
  invoice_date_due DATE,                      -- Due date

  -- Amounts
  currency_id INTEGER,
  currency_code TEXT,
  amount_untaxed DECIMAL(15, 2) DEFAULT 0,
  amount_tax DECIMAL(15, 2) DEFAULT 0,
  amount_total DECIMAL(15, 2) DEFAULT 0,
  amount_residual DECIMAL(15, 2) DEFAULT 0,   -- Amount remaining to pay

  -- Payment
  payment_state TEXT,                         -- 'not_paid', 'in_payment', 'paid', 'partial', 'reversed'

  -- Sales
  invoice_user_id INTEGER,                    -- Salesperson
  team_id INTEGER,                            -- Sales team
  campaign_id INTEGER,                        -- Marketing campaign

  -- Source documents
  invoice_origin TEXT,                        -- e.g., 'SO001'

  -- Notes
  narration TEXT,

  -- Metadata
  posted_before BOOLEAN DEFAULT FALSE,

  -- Sync tracking
  odoo_write_date TIMESTAMPTZ,
  sync_status mirror.sync_status DEFAULT 'pending',
  last_synced_at TIMESTAMPTZ,

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes
CREATE INDEX idx_account_move_name ON mirror.account_move(name);
CREATE INDEX idx_account_move_partner ON mirror.account_move(partner_id);
CREATE INDEX idx_account_move_company ON mirror.account_move(company_id);
CREATE INDEX idx_account_move_date ON mirror.account_move(date DESC);
CREATE INDEX idx_account_move_due ON mirror.account_move(invoice_date_due) WHERE invoice_date_due IS NOT NULL;
CREATE INDEX idx_account_move_state ON mirror.account_move(state);
CREATE INDEX idx_account_move_type ON mirror.account_move(move_type);
CREATE INDEX idx_account_move_payment ON mirror.account_move(payment_state) WHERE payment_state IS NOT NULL;
CREATE INDEX idx_account_move_unpaid ON mirror.account_move(invoice_date_due, amount_residual)
  WHERE state = 'posted' AND amount_residual > 0;
CREATE INDEX idx_account_move_sync ON mirror.account_move(sync_status, last_synced_at);

-- ============================================================================
-- TABLE: mirror.sale_order
-- ============================================================================
-- Purpose: Mirror of Odoo sales orders
-- ============================================================================

CREATE TABLE mirror.sale_order (
  -- Primary key (matches Odoo ID)
  id INTEGER PRIMARY KEY,

  -- Core fields
  name TEXT NOT NULL,                         -- Order number (e.g., SO001)

  -- State
  state mirror.order_state NOT NULL DEFAULT 'draft',

  -- Relationships
  partner_id INTEGER REFERENCES mirror.res_partner(id),
  partner_invoice_id INTEGER REFERENCES mirror.res_partner(id),
  partner_shipping_id INTEGER REFERENCES mirror.res_partner(id),
  company_id INTEGER REFERENCES mirror.res_company(id),

  -- Sales
  user_id INTEGER,                            -- Salesperson
  team_id INTEGER,                            -- Sales team

  -- Dates
  date_order TIMESTAMPTZ NOT NULL,            -- Order date
  validity_date DATE,                         -- Quotation validity
  commitment_date TIMESTAMPTZ,                -- Delivery commitment

  -- Amounts
  currency_id INTEGER,
  currency_code TEXT,
  amount_untaxed DECIMAL(15, 2) DEFAULT 0,
  amount_tax DECIMAL(15, 2) DEFAULT 0,
  amount_total DECIMAL(15, 2) DEFAULT 0,

  -- Payment
  payment_term_id INTEGER,

  -- Source
  origin TEXT,                                -- Source document
  client_order_ref TEXT,                      -- Customer reference

  -- Notes
  note TEXT,

  -- Invoicing
  invoice_status TEXT,                        -- 'upselling', 'invoiced', 'to invoice', 'no'

  -- Metadata
  require_signature BOOLEAN DEFAULT FALSE,
  require_payment BOOLEAN DEFAULT FALSE,

  -- Sync tracking
  odoo_write_date TIMESTAMPTZ,
  sync_status mirror.sync_status DEFAULT 'pending',
  last_synced_at TIMESTAMPTZ,

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes
CREATE INDEX idx_sale_order_name ON mirror.sale_order(name);
CREATE INDEX idx_sale_order_partner ON mirror.sale_order(partner_id);
CREATE INDEX idx_sale_order_company ON mirror.sale_order(company_id);
CREATE INDEX idx_sale_order_date ON mirror.sale_order(date_order DESC);
CREATE INDEX idx_sale_order_state ON mirror.sale_order(state);
CREATE INDEX idx_sale_order_user ON mirror.sale_order(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX idx_sale_order_team ON mirror.sale_order(team_id) WHERE team_id IS NOT NULL;
CREATE INDEX idx_sale_order_to_invoice ON mirror.sale_order(invoice_status) WHERE invoice_status = 'to invoice';
CREATE INDEX idx_sale_order_sync ON mirror.sale_order(sync_status, last_synced_at);

-- ============================================================================
-- TABLE: mirror.product_template
-- ============================================================================
-- Purpose: Mirror of Odoo product templates
-- ============================================================================

CREATE TABLE mirror.product_template (
  -- Primary key (matches Odoo ID)
  id INTEGER PRIMARY KEY,

  -- Core fields
  name TEXT NOT NULL,
  display_name TEXT,
  description TEXT,
  description_sale TEXT,                      -- Customer-facing description

  -- Type
  type TEXT,                                  -- 'consu', 'service', 'product'
  detailed_type TEXT,

  -- Pricing
  list_price DECIMAL(15, 2),                  -- Sale price
  standard_price DECIMAL(15, 2),              -- Cost
  currency_id INTEGER,

  -- Categorization
  categ_id INTEGER,
  default_code TEXT,                          -- Internal reference
  barcode TEXT,

  -- Sales
  sale_ok BOOLEAN DEFAULT TRUE,
  purchase_ok BOOLEAN DEFAULT TRUE,

  -- Stock
  tracking TEXT,                              -- 'serial', 'lot', 'none'

  -- Metadata
  active BOOLEAN DEFAULT TRUE,
  company_id INTEGER REFERENCES mirror.res_company(id),

  -- Sync tracking
  odoo_write_date TIMESTAMPTZ,
  sync_status mirror.sync_status DEFAULT 'pending',
  last_synced_at TIMESTAMPTZ,

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes
CREATE INDEX idx_product_template_name ON mirror.product_template(name);
CREATE INDEX idx_product_template_code ON mirror.product_template(default_code) WHERE default_code IS NOT NULL;
CREATE INDEX idx_product_template_barcode ON mirror.product_template(barcode) WHERE barcode IS NOT NULL;
CREATE INDEX idx_product_template_categ ON mirror.product_template(categ_id) WHERE categ_id IS NOT NULL;
CREATE INDEX idx_product_template_active ON mirror.product_template(active) WHERE active = TRUE;
CREATE INDEX idx_product_template_sale ON mirror.product_template(sale_ok) WHERE sale_ok = TRUE;
CREATE INDEX idx_product_template_sync ON mirror.product_template(sync_status, last_synced_at);

-- ============================================================================
-- TABLE: mirror.res_users
-- ============================================================================
-- Purpose: Mirror of Odoo users (for reference, not auth)
-- ============================================================================

CREATE TABLE mirror.res_users (
  -- Primary key (matches Odoo ID)
  id INTEGER PRIMARY KEY,

  -- Core fields
  name TEXT NOT NULL,
  login TEXT NOT NULL,                        -- Odoo username

  -- Link to partner
  partner_id INTEGER REFERENCES mirror.res_partner(id),
  company_id INTEGER REFERENCES mirror.res_company(id),

  -- Access
  active BOOLEAN DEFAULT TRUE,
  share BOOLEAN DEFAULT FALSE,               -- Portal user

  -- Metadata
  lang TEXT,
  tz TEXT,

  -- Group IDs (Odoo groups)
  groups_ids INTEGER[] DEFAULT '{}',

  -- Sync tracking
  odoo_write_date TIMESTAMPTZ,
  sync_status mirror.sync_status DEFAULT 'pending',
  last_synced_at TIMESTAMPTZ,

  -- Audit
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Indexes
CREATE INDEX idx_res_users_login ON mirror.res_users(login);
CREATE INDEX idx_res_users_partner ON mirror.res_users(partner_id);
CREATE INDEX idx_res_users_company ON mirror.res_users(company_id);
CREATE INDEX idx_res_users_active ON mirror.res_users(active) WHERE active = TRUE;
CREATE INDEX idx_res_users_sync ON mirror.res_users(sync_status, last_synced_at);

-- ============================================================================
-- FUNCTIONS: Sync Helpers
-- ============================================================================

-- Function to start a sync operation
CREATE OR REPLACE FUNCTION mirror.start_sync(
  p_table_name TEXT,
  p_operation TEXT DEFAULT 'incremental',
  p_odoo_model TEXT DEFAULT NULL,
  p_odoo_domain TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_log_id UUID;
BEGIN
  INSERT INTO mirror.sync_log (
    table_name, operation, status,
    odoo_model, odoo_domain
  ) VALUES (
    p_table_name, p_operation, 'syncing',
    p_odoo_model, p_odoo_domain
  )
  RETURNING id INTO v_log_id;

  RETURN v_log_id;
END;
$$;

-- Function to complete a sync operation
CREATE OR REPLACE FUNCTION mirror.complete_sync(
  p_log_id UUID,
  p_records_fetched INTEGER DEFAULT 0,
  p_records_created INTEGER DEFAULT 0,
  p_records_updated INTEGER DEFAULT 0,
  p_records_deleted INTEGER DEFAULT 0
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE mirror.sync_log
  SET
    status = 'synced',
    ended_at = now(),
    duration_ms = EXTRACT(MILLISECONDS FROM now() - started_at)::INTEGER,
    records_fetched = p_records_fetched,
    records_created = p_records_created,
    records_updated = p_records_updated,
    records_deleted = p_records_deleted
  WHERE id = p_log_id;
END;
$$;

-- Function to fail a sync operation
CREATE OR REPLACE FUNCTION mirror.fail_sync(
  p_log_id UUID,
  p_error_message TEXT,
  p_error_details JSONB DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE mirror.sync_log
  SET
    status = 'failed',
    ended_at = now(),
    duration_ms = EXTRACT(MILLISECONDS FROM now() - started_at)::INTEGER,
    error_message = p_error_message,
    error_details = p_error_details
  WHERE id = p_log_id;
END;
$$;

-- Function to get sync status
CREATE OR REPLACE FUNCTION mirror.get_sync_status()
RETURNS TABLE (
  table_name TEXT,
  last_sync_at TIMESTAMPTZ,
  last_status mirror.sync_status,
  records_count BIGINT,
  oldest_record TIMESTAMPTZ,
  stale_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH latest_syncs AS (
    SELECT DISTINCT ON (sl.table_name)
      sl.table_name,
      sl.ended_at,
      sl.status
    FROM mirror.sync_log sl
    ORDER BY sl.table_name, sl.started_at DESC
  )
  SELECT
    t.table_name::TEXT,
    ls.ended_at AS last_sync_at,
    ls.status AS last_status,
    CASE t.table_name
      WHEN 'res_partner' THEN (SELECT COUNT(*) FROM mirror.res_partner)
      WHEN 'account_move' THEN (SELECT COUNT(*) FROM mirror.account_move)
      WHEN 'sale_order' THEN (SELECT COUNT(*) FROM mirror.sale_order)
      WHEN 'product_template' THEN (SELECT COUNT(*) FROM mirror.product_template)
      WHEN 'res_company' THEN (SELECT COUNT(*) FROM mirror.res_company)
      WHEN 'res_users' THEN (SELECT COUNT(*) FROM mirror.res_users)
      ELSE 0
    END AS records_count,
    CASE t.table_name
      WHEN 'res_partner' THEN (SELECT MIN(last_synced_at) FROM mirror.res_partner)
      WHEN 'account_move' THEN (SELECT MIN(last_synced_at) FROM mirror.account_move)
      WHEN 'sale_order' THEN (SELECT MIN(last_synced_at) FROM mirror.sale_order)
      WHEN 'product_template' THEN (SELECT MIN(last_synced_at) FROM mirror.product_template)
      WHEN 'res_company' THEN (SELECT MIN(last_synced_at) FROM mirror.res_company)
      WHEN 'res_users' THEN (SELECT MIN(last_synced_at) FROM mirror.res_users)
    END AS oldest_record,
    CASE t.table_name
      WHEN 'res_partner' THEN (SELECT COUNT(*) FROM mirror.res_partner WHERE sync_status = 'stale')
      WHEN 'account_move' THEN (SELECT COUNT(*) FROM mirror.account_move WHERE sync_status = 'stale')
      WHEN 'sale_order' THEN (SELECT COUNT(*) FROM mirror.sale_order WHERE sync_status = 'stale')
      WHEN 'product_template' THEN (SELECT COUNT(*) FROM mirror.product_template WHERE sync_status = 'stale')
      WHEN 'res_company' THEN (SELECT COUNT(*) FROM mirror.res_company WHERE sync_status = 'stale')
      WHEN 'res_users' THEN (SELECT COUNT(*) FROM mirror.res_users WHERE sync_status = 'stale')
      ELSE 0
    END AS stale_count
  FROM (
    VALUES
      ('res_partner'),
      ('account_move'),
      ('sale_order'),
      ('product_template'),
      ('res_company'),
      ('res_users')
  ) AS t(table_name)
  LEFT JOIN latest_syncs ls ON ls.table_name = t.table_name;
END;
$$;

-- ============================================================================
-- VIEWS: Convenient access patterns
-- ============================================================================

-- Active customers
CREATE OR REPLACE VIEW mirror.v_customers AS
SELECT
  id,
  name,
  email,
  phone,
  city,
  country_code,
  customer_rank,
  vat,
  company_id,
  last_synced_at
FROM mirror.res_partner
WHERE active = TRUE
  AND customer_rank > 0
ORDER BY customer_rank DESC, name;

-- Active vendors
CREATE OR REPLACE VIEW mirror.v_vendors AS
SELECT
  id,
  name,
  email,
  phone,
  city,
  country_code,
  supplier_rank,
  vat,
  company_id,
  last_synced_at
FROM mirror.res_partner
WHERE active = TRUE
  AND supplier_rank > 0
ORDER BY supplier_rank DESC, name;

-- Open invoices
CREATE OR REPLACE VIEW mirror.v_open_invoices AS
SELECT
  m.id,
  m.name,
  m.move_type,
  m.partner_id,
  p.name AS partner_name,
  m.invoice_date,
  m.invoice_date_due,
  m.amount_total,
  m.amount_residual,
  m.currency_code,
  m.payment_state,
  m.company_id,
  CASE
    WHEN m.invoice_date_due < CURRENT_DATE THEN 'overdue'
    WHEN m.invoice_date_due < CURRENT_DATE + 7 THEN 'due_soon'
    ELSE 'on_time'
  END AS due_status,
  CURRENT_DATE - m.invoice_date_due AS days_overdue
FROM mirror.account_move m
LEFT JOIN mirror.res_partner p ON p.id = m.partner_id
WHERE m.state = 'posted'
  AND m.amount_residual > 0
ORDER BY m.invoice_date_due ASC;

-- Recent sales orders
CREATE OR REPLACE VIEW mirror.v_recent_orders AS
SELECT
  o.id,
  o.name,
  o.state,
  o.partner_id,
  p.name AS partner_name,
  o.date_order,
  o.amount_total,
  o.currency_code,
  o.invoice_status,
  o.user_id,
  o.company_id
FROM mirror.sale_order o
LEFT JOIN mirror.res_partner p ON p.id = o.partner_id
WHERE o.date_order > now() - interval '30 days'
ORDER BY o.date_order DESC;

-- Sync health summary
CREATE OR REPLACE VIEW mirror.v_sync_health AS
SELECT
  table_name,
  last_sync_at,
  last_status,
  records_count,
  stale_count,
  CASE
    WHEN last_status = 'failed' THEN 'error'
    WHEN last_sync_at < now() - interval '1 hour' THEN 'stale'
    WHEN stale_count > 0 THEN 'warning'
    ELSE 'healthy'
  END AS health_status
FROM mirror.get_sync_status();

-- ============================================================================
-- TRIGGERS: Auto-update timestamps
-- ============================================================================

CREATE TRIGGER tr_res_company_updated_at
  BEFORE UPDATE ON mirror.res_company
  FOR EACH ROW EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_res_partner_updated_at
  BEFORE UPDATE ON mirror.res_partner
  FOR EACH ROW EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_account_move_updated_at
  BEFORE UPDATE ON mirror.account_move
  FOR EACH ROW EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_sale_order_updated_at
  BEFORE UPDATE ON mirror.sale_order
  FOR EACH ROW EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_product_template_updated_at
  BEFORE UPDATE ON mirror.product_template
  FOR EACH ROW EXECUTE FUNCTION ops.update_updated_at();

CREATE TRIGGER tr_res_users_updated_at
  BEFORE UPDATE ON mirror.res_users
  FOR EACH ROW EXECUTE FUNCTION ops.update_updated_at();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON SCHEMA mirror IS 'Read-only mirrors of Odoo data. Odoo remains System of Record. Never write directly to Odoo from here.';

COMMENT ON TABLE mirror.res_partner IS 'Mirror of Odoo res.partner - customers, vendors, and contacts';
COMMENT ON TABLE mirror.account_move IS 'Mirror of Odoo account.move - invoices and journal entries';
COMMENT ON TABLE mirror.sale_order IS 'Mirror of Odoo sale.order - sales orders and quotations';
COMMENT ON TABLE mirror.product_template IS 'Mirror of Odoo product.template - product catalog';
COMMENT ON TABLE mirror.res_company IS 'Mirror of Odoo res.company - multi-company support';
COMMENT ON TABLE mirror.res_users IS 'Mirror of Odoo res.users - user reference (not for auth)';
COMMENT ON TABLE mirror.sync_log IS 'Audit trail of all sync operations from Odoo';
