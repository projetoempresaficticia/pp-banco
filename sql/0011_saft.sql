-- Prepacoin: exportar o SAF-T (PT) do período.
--
-- Na vida real o SAF-T sai do programa de faturação, não do Portal das
-- Finanças. No nosso mundo o programa de faturação é o Prepacoin — por isso
-- é aqui que o ficheiro nasce. O formando descarrega-o daqui e entrega-o na
-- AT, tal como se faz a sério.
--
-- Monta-se no servidor, não no browser: os dados têm de vir da fonte de
-- verdade, e o cliente não pode ser quem decide o que declara. A AT recebe
-- o ficheiro e recalcula os mesmos totais a partir das faturas que ela
-- própria vê — se não baterem, rejeita.
--
-- Duas simplificações, assumidas de olhos abertos:
--   · O IVA é derivado a 23% do valor_total, tratado como valor COM imposto:
--     base = total / 1,23, imposto = total - base. A faturas não guarda taxa.
--   · Não há NIF no ecossistema; o TaxRegistrationNumber leva a cédula.
--     A moeda é PPC (Prepacoin), não EUR.
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-05.

-- As descrições das faturas são texto livre: um "&" ou um "<" partiam o XML.
create or replace function public.fn_xml_texto(p_texto text)
returns text
language sql
immutable
set search_path = public
as $$
  select replace(replace(replace(coalesce(p_texto, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

revoke execute on function public.fn_xml_texto(text) from public, anon, authenticated;

create or replace function public.banco_saft(p_competencia text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cedula     text := public.fn_minha_empresa_cedula();
  v_nome       text;
  v_inicio     date;
  v_fim        date;
  v_linhas     text := '';
  v_n          int    := 0;
  v_bruto      bigint := 0;
  v_liquido    bigint := 0;
  v_imposto    bigint := 0;
  v_base       bigint;
  v_iva        bigint;
  v_xml        text;
  r            record;
begin
  if v_cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem empresa associada à sessão.');
  end if;
  -- "is null or" nao e redundante: com p_competencia nulo, o !~ devolve
  -- NULL e o if nao dispara. Sem isto sai um SAF-T sem datas e vazio.
  if p_competencia is null or p_competencia !~ '^\d{4}-(0[1-9]|1[0-2])$' then
    return jsonb_build_object('ok', false, 'erro', 'Competência inválida. Use AAAA-MM.');
  end if;

  select nome into v_nome from public.empresas where cedula = v_cedula;
  v_inicio := (p_competencia || '-01')::date;
  v_fim    := (v_inicio + interval '1 month - 1 day')::date;

  for r in
    select numero, devedor_cedula, descricao, valor_total, emitida_em
      from public.faturas
     where emitente_cedula = v_cedula
       and emitida_em >= v_inicio
       and emitida_em <  v_inicio + interval '1 month'
       -- "is distinct from" e não "<>": com estado nulo, o <> dá NULL e a
       -- fatura desaparecia do ficheiro sem ninguém dar por isso.
       and estado is distinct from 'anulada'
     order by numero
  loop
    v_base := round(r.valor_total / 1.23)::bigint;
    v_iva  := r.valor_total - v_base;

    v_n       := v_n + 1;
    v_bruto   := v_bruto + r.valor_total;
    v_liquido := v_liquido + v_base;
    v_imposto := v_imposto + v_iva;

    v_linhas := v_linhas || format(
      E'      <Invoice>\n'
      || E'        <InvoiceNo>%s</InvoiceNo>\n'
      || E'        <InvoiceDate>%s</InvoiceDate>\n'
      || E'        <CustomerID>%s</CustomerID>\n'
      || E'        <Line>\n'
      || E'          <Description>%s</Description>\n'
      || E'          <CreditAmount>%s</CreditAmount>\n'
      || E'        </Line>\n'
      || E'        <DocumentTotals>\n'
      || E'          <TaxPayable>%s</TaxPayable>\n'
      || E'          <NetTotal>%s</NetTotal>\n'
      || E'          <GrossTotal>%s</GrossTotal>\n'
      || E'        </DocumentTotals>\n'
      || E'      </Invoice>\n',
      public.fn_xml_texto(r.numero),
      to_char(r.emitida_em, 'YYYY-MM-DD'),
      public.fn_xml_texto(r.devedor_cedula),
      public.fn_xml_texto(r.descricao),
      to_char(v_base / 100.0, 'FM9999999990.00'),
      to_char(v_iva / 100.0, 'FM9999999990.00'),
      to_char(v_base / 100.0, 'FM9999999990.00'),
      to_char(r.valor_total / 100.0, 'FM9999999990.00'));
  end loop;

  v_xml := format(
    E'<?xml version="1.0" encoding="UTF-8"?>\n'
    || E'<AuditFile>\n'
    || E'  <Header>\n'
    || E'    <AuditFileVersion>1.04_01</AuditFileVersion>\n'
    || E'    <CompanyID>%s</CompanyID>\n'
    || E'    <TaxRegistrationNumber>%s</TaxRegistrationNumber>\n'
    || E'    <CompanyName>%s</CompanyName>\n'
    || E'    <FiscalYear>%s</FiscalYear>\n'
    || E'    <StartDate>%s</StartDate>\n'
    || E'    <EndDate>%s</EndDate>\n'
    || E'    <CurrencyCode>PPC</CurrencyCode>\n'
    || E'    <ProductID>Prepacoin/Prepara Portugal</ProductID>\n'
    || E'  </Header>\n'
    || E'  <SourceDocuments>\n'
    || E'    <SalesInvoices>\n'
    || E'      <NumberOfEntries>%s</NumberOfEntries>\n'
    || E'      <TotalDebit>0.00</TotalDebit>\n'
    || E'      <TotalCredit>%s</TotalCredit>\n'
    || E'%s'
    || E'    </SalesInvoices>\n'
    || E'  </SourceDocuments>\n'
    || E'</AuditFile>\n',
    public.fn_xml_texto(v_cedula),
    public.fn_xml_texto(v_cedula),
    public.fn_xml_texto(v_nome),
    left(p_competencia, 4),
    to_char(v_inicio, 'YYYY-MM-DD'),
    to_char(v_fim, 'YYYY-MM-DD'),
    v_n,
    to_char(v_liquido / 100.0, 'FM9999999990.00'),
    v_linhas);

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'competencia', p_competencia,
    'empresa', v_cedula,
    'nome', v_nome,
    'faturas', v_n,
    'liquido', v_liquido,
    'imposto', v_imposto,
    'bruto', v_bruto,
    'ficheiro', format('SAFT-%s-%s.xml', v_cedula, p_competencia),
    'xml', v_xml));
exception when others then
  -- Sem sqlerrm: o erro cru do Postgres não vai ao browser (R1 da pp-base).
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível gerar o SAF-T.');
end;
$$;

revoke execute on function public.banco_saft(text) from public, anon;
grant execute on function public.banco_saft(text) to authenticated;
