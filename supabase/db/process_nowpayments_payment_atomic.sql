CREATE OR REPLACE FUNCTION public.process_nowpayments_payment_atomic(p_event_id text, p_provider_payment_id text, p_order_id text, p_provider_status text, p_price_amount numeric, p_price_currency text, p_pay_currency text, p_pay_amount numeric, p_actually_paid numeric, p_raw jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
declare
  v_payment public.payments%rowtype;
  v_batch public.checkout_batches%rowtype;
  v_width integer;
  v_status text;
  v_expected numeric;
  v_conflicts jsonb;
  v_row record;
  v_mark_count integer;
  v_other_active boolean;
  v_currency text;
begin
  if p_event_id is null or length(p_event_id)<16 then return jsonb_build_object('ok',false,'code','INVALID_EVENT_ID'); end if;

  insert into public.webhook_events(provider,provider_event_id) values('nowpayments',p_event_id)
  on conflict(provider,provider_event_id) do nothing;

  if nullif(trim(coalesce(p_provider_payment_id,'')),'') is not null then
    select * into v_payment from public.payments where provider='nowpayments' and provider_payment_id=p_provider_payment_id limit 1 for update;
  end if;
  if not found and nullif(trim(coalesce(p_order_id,'')),'') is not null then
    select * into v_payment from public.payments where provider='nowpayments' and provider_order_id=p_order_id order by created_at desc limit 1 for update;
  end if;
  if not found then return jsonb_build_object('ok',false,'code','PAYMENT_NOT_FOUND'); end if;

  if v_payment.provider_order_id is distinct from p_order_id then return jsonb_build_object('ok',false,'code','ORDER_MISMATCH'); end if;
  if v_payment.provider_payment_id is not null and v_payment.provider_payment_id is distinct from p_provider_payment_id then
    return jsonb_build_object('ok',false,'code','PROVIDER_PAYMENT_MISMATCH');
  end if;
  if v_payment.environment is distinct from 'live_mode' then
    return jsonb_build_object('ok',false,'code','NON_LIVE_PAYMENT_BLOCKED');
  end if;

  select * into v_batch from public.checkout_batches where id=v_payment.batch_id for update;
  if not found then return jsonb_build_object('ok',false,'code','BATCH_NOT_FOUND'); end if;

  v_status := lower(coalesce(p_provider_status,''));

  if v_status='refunded' then
    v_currency := upper(trim(coalesce(p_price_currency,'')));
    if v_currency !~ '^[A-Z]{3}$' then v_currency := null; end if;
    insert into public.payment_reversal_events(
      provider,provider_event_id,payment_id,provider_payment_id,event_type,resource_id,amount_text,currency,is_partial,occurred_at
    ) values (
      'nowpayments',p_event_id,v_payment.id,coalesce(v_payment.provider_payment_id,p_provider_payment_id),
      'payment.refunded',coalesce(v_payment.provider_payment_id,p_provider_payment_id),
      coalesce(p_actually_paid,p_pay_amount)::text,v_currency,null,now()
    ) on conflict(provider,provider_event_id) do nothing;
  end if;

  if v_batch.status='paid' then
    update public.webhook_events set processed_at=now()
      where provider='nowpayments' and provider_event_id=p_event_id and processed_at is null;
    select count(*) into v_mark_count from public.marks where batch_id=v_batch.id;
    return jsonb_build_object(
      'ok',true,
      'action',case when v_status='finished' then 'DUPLICATE_PAYMENT_AFTER_SEAL' when v_status='refunded' then 'FINANCIAL_REVERSAL_RECORDED' else 'IGNORED_AFTER_PAID' end,
      'status',v_status,'sealed_marks',v_mark_count
    );
  end if;

  v_expected := v_batch.amount_minor::numeric/100.0;
  if lower(coalesce(p_price_currency,'')) <> 'usd' or abs(coalesce(p_price_amount,0)-v_expected) > 0.01 then
    update public.payments set provider_status='amount_mismatch',provider_payload=p_raw,updated_at=now() where id=v_payment.id;
    return jsonb_build_object('ok',false,'code','AMOUNT_MISMATCH');
  end if;

  if v_status='finished' and (v_payment.pay_amount is null or v_payment.pay_amount<=0 or p_pay_amount is null or p_pay_amount<=0 or p_actually_paid is null or p_actually_paid<greatest(v_payment.pay_amount,p_pay_amount)) then
    update public.payments set provider_status='manual_review_underpayment',provider_payload=p_raw,
      actually_paid=p_actually_paid,updated_at=now() where id=v_payment.id;
    return jsonb_build_object('ok',false,'code','UNDERPAYMENT_BLOCKED');
  end if;

  update public.payments
  set provider_payment_id=coalesce(provider_payment_id,p_provider_payment_id),provider_status=v_status,
      pay_currency=lower(coalesce(p_pay_currency,pay_currency)),
      actually_paid=p_actually_paid,provider_payload=p_raw,updated_at=now()
  where id=v_payment.id;

  if v_status in ('confirming','confirmed','sending','partially_paid') then
    update public.checkout_batches set expires_at=greatest(expires_at,now()+interval '24 hours'),updated_at=now() where id=v_batch.id and status<>'paid';
    update public.reservation_cells set expires_at=greatest(expires_at,now()+interval '24 hours') where batch_id=v_batch.id;
    return jsonb_build_object('ok',true,'action','EXTENDED','status',v_status);
  end if;

  if v_status in ('failed','expired','refunded') then
    update public.payments set status=case when v_status='refunded' then 'refunded'::public.payment_status else 'failed'::public.payment_status end,updated_at=now() where id=v_payment.id;
    select exists(select 1 from public.payments p where p.batch_id=v_batch.id and p.provider='nowpayments' and p.id<>v_payment.id
      and p.status in ('created','pending') and lower(coalesce(p.provider_status,'')) not in ('failed','expired','refunded')) into v_other_active;
    if v_other_active then return jsonb_build_object('ok',true,'action','ALTERNATIVE_INVOICE_STILL_ACTIVE','status',v_status); end if;
    delete from public.reservation_cells where batch_id=v_batch.id;
    update public.checkout_batches set status=case when v_status='expired' then 'expired'::public.batch_status else 'cancelled'::public.batch_status end,updated_at=now()
      where id=v_batch.id and status<>'paid';
    return jsonb_build_object('ok',true,'action','RELEASED','status',v_status);
  end if;

  if v_status <> 'finished' then return jsonb_build_object('ok',true,'action','NOOP','status',v_status); end if;

  select width into v_width from public.canvas_state where canvas=v_batch.canvas;
  if (select count(*) from public.batch_cells where batch_id=v_batch.id) <> v_batch.item_count then
    update public.payments set provider_status='manual_review_batch_cells_missing',updated_at=now() where id=v_payment.id;
    return jsonb_build_object('ok',false,'code','BATCH_CELLS_MISSING');
  end if;

  for v_row in select x,y from public.batch_cells where batch_id=v_batch.id order by (y::bigint*v_width::bigint+x::bigint)
  loop
    perform pg_advisory_xact_lock(hashtext(v_batch.canvas::text),(v_row.y*v_width+v_row.x));
  end loop;

  delete from public.reservation_cells r using public.batch_cells b
  where b.batch_id=v_batch.id and r.canvas=b.canvas and r.x=b.x and r.y=b.y and r.expires_at<=now();

  select coalesce(jsonb_agg(jsonb_build_object('x',q.x,'y',q.y,'reason',q.reason) order by q.y,q.x),'[]'::jsonb)
  into v_conflicts
  from (
    select b.x,b.y,case when exists(select 1 from public.marks m where m.canvas=b.canvas and m.x=b.x and m.y=b.y) then 'sealed' else 'reserved_by_other' end as reason
    from public.batch_cells b
    where b.batch_id=v_batch.id and (
      exists(select 1 from public.marks m where m.canvas=b.canvas and m.x=b.x and m.y=b.y)
      or exists(select 1 from public.reservation_cells r where r.canvas=b.canvas and r.x=b.x and r.y=b.y and r.batch_id<>v_batch.id and r.expires_at>now())
  )) q;

  if jsonb_array_length(v_conflicts)>0 then
    update public.payments set provider_status='manual_review_paid_cell_conflict',provider_payload=p_raw,updated_at=now() where id=v_payment.id;
    return jsonb_build_object('ok',false,'code','PAID_CELL_CONFLICT','conflicts',v_conflicts);
  end if;

  select count(*) into v_mark_count from public.marks where batch_id=v_batch.id;
  if v_mark_count <> 0 then
    update public.payments set provider_status='manual_review_preexisting_partial_seal',updated_at=now() where id=v_payment.id;
    return jsonb_build_object('ok',false,'code','PREEXISTING_PARTIAL_SEAL','sealed_marks',v_mark_count);
  end if;

  begin
    insert into public.marks(canvas,x,y,color_id,country_code,ai_provider,ai_model,payment_id,batch_id,certificate_id,share_slug)
    select b.canvas,b.x,b.y,b.color_id,v_batch.country_code,v_batch.ai_provider,v_batch.ai_model,v_payment.id,v_batch.id,
      'H1-'||upper(substr(encode(extensions.gen_random_bytes(10),'hex'),1,16)),lower(encode(extensions.gen_random_bytes(9),'hex'))
    from public.batch_cells b where b.batch_id=v_batch.id
    on conflict(canvas,x,y) do nothing;
    select count(*) into v_mark_count from public.marks where batch_id=v_batch.id;
    if v_mark_count <> v_batch.item_count then raise exception using errcode='P5001',message='H1_PARTIAL_SEAL_ROLLBACK'; end if;
  exception when sqlstate 'P5001' then
    update public.payments set provider_status='manual_review_partial_seal',updated_at=now() where id=v_payment.id;
    return jsonb_build_object('ok',false,'code','PARTIAL_SEAL_BLOCKED','sealed_marks',0);
  end;

  delete from public.reservation_cells where batch_id=v_batch.id;
  update public.payments set status='paid',provider_status='finished',paid_at=coalesce(paid_at,now()),provider_payload=p_raw,updated_at=now() where id=v_payment.id;
  update public.checkout_batches set status='paid',updated_at=now() where id=v_batch.id;
  update public.canvas_state set sealed_count=sealed_count+v_batch.item_count,updated_at=now() where canvas=v_batch.canvas;
  update public.webhook_events set processed_at=now() where provider='nowpayments' and provider_event_id=p_event_id;
  return jsonb_build_object('ok',true,'action','SEALED','sealed_marks',v_mark_count,'batch_id',v_batch.id);
end;
$function$;
