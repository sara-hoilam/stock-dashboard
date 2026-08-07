-- Ticker Alpha — per-symbol dividend history (ex-date + amount)
--
-- Apply after 0036. Safe to re-run.
--
-- The worker writes rows from FMP's /dividends?symbol=… when it fetches
-- prices. The portfolio page reads upcoming and recent events so it can
-- credit cash on ex-dividend date for holdings logged before that date.

create table if not exists ledger.dividend_event (
  symbol            text not null,
  ex_date           date not null,
  amount            double precision,
  adj_amount        double precision,
  yield             double precision,
  frequency         text,
  declaration_date  date,
  record_date       date,
  payment_date      date,
  updated_at        timestamptz not null default now(),
  primary key (symbol, ex_date)
);
create index if not exists dividend_event_ex_date_idx
  on ledger.dividend_event (ex_date);
create index if not exists dividend_event_symbol_ex_idx
  on ledger.dividend_event (symbol, ex_date desc);

alter table ledger.dividend_event enable row level security;

-- Replace all stored dividends for one symbol (full history from FMP).
create or replace function public.replace_symbol_dividends(
  p_symbol text,
  p_rows   jsonb
)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare
  v_sym text := upper(trim(coalesce(p_symbol, '')));
  n integer := 0;
begin
  if v_sym !~ '^[A-Z][A-Z.\-]{0,9}$' then
    return 0;
  end if;

  delete from ledger.dividend_event where symbol = v_sym;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return 0;
  end if;

  insert into ledger.dividend_event
    (symbol, ex_date, amount, adj_amount, yield, frequency,
     declaration_date, record_date, payment_date, updated_at)
  select v_sym,
         nullif(r->>'exDate', '')::date,
         nullif(r->>'amount', '')::double precision,
         nullif(r->>'adjAmount', '')::double precision,
         nullif(r->>'yield', '')::double precision,
         nullif(r->>'frequency', ''),
         nullif(r->>'declarationDate', '')::date,
         nullif(r->>'recordDate', '')::date,
         nullif(r->>'paymentDate', '')::date,
         now()
  from jsonb_array_elements(p_rows) r
  where nullif(r->>'exDate', '') is not null
  on conflict (symbol, ex_date) do update set
    amount = excluded.amount,
    adj_amount = excluded.adj_amount,
    yield = excluded.yield,
    frequency = excluded.frequency,
    declaration_date = excluded.declaration_date,
    record_date = excluded.record_date,
    payment_date = excluded.payment_date,
    updated_at = now();

  get diagnostics n = row_count;
  return n;
end;
$$;

-- Dividends for a set of symbols (about two years back through upcoming).
create or replace function public.get_symbol_dividends(p_symbols text[])
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', d.symbol,
           'exDate', d.ex_date,
           'amount', coalesce(d.adj_amount, d.amount),
           'yield', d.yield,
           'frequency', d.frequency,
           'declarationDate', d.declaration_date,
           'recordDate', d.record_date,
           'paymentDate', d.payment_date)
         order by d.symbol, d.ex_date), '[]'::jsonb)
  from ledger.dividend_event d
  where d.symbol = any (
          select upper(trim(s)) from unnest(coalesce(p_symbols, array[]::text[])) s
          where upper(trim(s)) ~ '^[A-Z][A-Z.\-]{0,9}$')
    and d.ex_date >= (current_date - interval '750 days')
    and coalesce(d.adj_amount, d.amount) is not null;
$$;

do $$
begin
  execute 'revoke all on function public.replace_symbol_dividends(text, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_symbol_dividends(text, jsonb) to service_role';

  execute 'revoke all on function public.get_symbol_dividends(text[]) from public';
  execute 'grant execute on function public.get_symbol_dividends(text[]) to anon, authenticated';
end $$;
