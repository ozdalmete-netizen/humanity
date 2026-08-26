CREATE OR REPLACE FUNCTION public.process_dodo_payment_atomic(p_event_id text, p_payment_row_id uuid, p_provider_payment_id text, p_checkout_session_id text, p_provider_status text, p_quantity integer, p_raw jsonb)
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
  v_conflicts jsonb;
  v_row record;
  v_mark_count integer;
  v_other_active boolean;
  v_processed timestamptz;
begin
  if p_event_id is null or length(p_event_id)<8 then return jsonb_build_object('ok',false,'code','INVALID_EVENT_ID'); end if;

  select processed_at into v_processed from public.webhook_events where provider='dodo' and provider_event_id=p_event_id;
  if found and v_processed is not null then return jsonb_build_object('ok',true,'action','DUPLICATE_EVENT'); end if;

  insert into public.webhook_events(provider,provider_event_id) values('dodo',p_event_id)
  on conflict(provider,provider_event_id) do nothing;

  select * into v_payment from public.payments where id=p_payment_row_id and provider='dodo' for update;
  if not found then return jsonb_build_object('ok',false,'code','PAYMENT_NOT_FOUND'); end if;
  select * into v_batch from public.checkout_batches where id=v_payment.batch_id for update;
  if not found then return jsonb_build_object('ok',false,'code','BATCH_NOT_FOUND'); end if;

  if v_payment.provider_payment_id is not null and v_payment.provider_payment_id is distinct from p_provider_payment_id then
    return jsonb_build_object('ok',false,'code','PROVIDER_PAYMENT_MISMATCH');
  end if;

  v_status := lower(coalesce(p_provider_status,''));

  if v_batch.status='paid' then
    update public.webhook_events set processed_at=now()
    where provider='dodo' and provider_event_id=p_event_id and processed_at is null;
    select count(*) into v_mark_count from public.marks where batch_id=v_batch.id;
    return jsonb_build_object('ok',true,'action',case when v_status='succeeded' then 'DUPLICATE_PAYMENT_AFTER_SEAL' else 'IGNORED_AFTER_PAID' end,
      'status',v_status,'sealed_marks',v_mark_count);
  end if;

  if v_payment.environment is distinct from 'live_mode'
     or coalesce(v_payment.provider_payload->>'environment','') <> 'live_mode'
     or coalesce(p_raw->>'environment','') <> 'live_mode' then
    update public.payments
      set provider_status='blocked_non_live_payment',provider_payload=coalesce(p_raw,provider_payload),updated_at=now()
      where id=v_payment.id;
    update public.webhook_events set processed_at=now()
      where provider='dodo' and provider_event_id=p_event_id and processed_at is null;
    return jsonb_build_object('ok',false,'code','NON_LIVE_PAYMENT_BLOCKED');
  end if;

  if coalesce(p_quantity,0) <> v_batch.item_count then
    update public.payments set provider_status='manual_review_quantity_mismatch',provider_payload=p_raw,updated_at=now() where id=v_payment.id;
    return jsonb_build_object('ok',false,'code','QUANTITY_MISMATCH');
  end if;

  update public.payments
  set provider_payment_id=coalesce(provider_payment_id,p_provider_payment_id),provider_status=v_status,
      provider_payload=p_raw,updated_at=now(),
      status=case when v_status='succeeded' then status when v_status in ('failed','cancelled') then 'failed'::public.payment_status else 'pending'::public.payment_status end
  where id=v_payment.id;

  if v_status in ('processing','requires_customer_action','requires_merchant_action','requires_payment_method','requires_confirmation','requires_capture') then
    update public.checkout_batches set expires_at=greatest(expires_at,now()+interval '24 hours'),updated_at=now() where id=v_batch.id and status<>'paid';
    update public.reservation_cells set expires_at=greatest(expires_at,now()+interval '24 hours') where batch_id=v_batch.id;
    return jsonb_build_object('ok',true,'action','EXTENDED','status',v_status);
  end if;

  if v_status in ('failed','cancelled') then
    select exists(select 1 from public.payments p where p.batch_id=v_batch.id and p.id<>v_payment.id
      and p.status in ('created','pending') and lower(coalesce(p.provider_status,'')) not in ('failed','cancelled','expired','refunded')) into v_other_active;
    if v_other_active then return jsonb_build_object('ok',true,'action','ALTERNATIVE_PAYMENT_STILL_ACTIVE','status',v_status); end if;
    delete from public.reservation_cells where batch_id=v_batch.id;
    update public.checkout_batches set status='cancelled',updated_at=now() where id=v_batch.id and status<>'paid';
    update public.webhook_events set processed_at=now() where provider='dodo' and provider_event_id=p_event_id;
    return jsonb_build_object('ok',true,'action','RELEASED','status',v_status);
  end if;

  if v_status <> 'succeeded' then return jsonb_build_object('ok',true,'action','NOOP','status',v_status); end if;

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
    on conflict (canvas,x,y) do nothing;

    select count(*) into v_mark_count from public.marks where batch_id=v_batch.id;
    if v_mark_count <> v_batch.item_count then raise exception using errcode='P5001', message='H1_PARTIAL_SEAL_ROLLBACK'; end if;
  exception when sqlstate 'P5001' then
    update public.payments set provider_status='manual_review_partial_seal',updated_at=now() where id=v_payment.id;
    return jsonb_build_object('ok',false,'code','PARTIAL_SEAL_BLOCKED','sealed_marks',0);
  end;

  delete from public.reservation_cells where batch_id=v_batch.id;
  update public.payments set status='paid',provider_status='succeeded',paid_at=coalesce(paid_at,now()),provider_payload=p_raw,updated_at=now() where id=v_payment.id;
  update public.checkout_batches set status='paid',updated_at=now() where id=v_batch.id;
  update public.canvas_state set sealed_count=sealed_count+v_batch.item_count,updated_at=now() where canvas=v_batch.canvas;
  update public.webhook_events set processed_at=now() where provider='dodo' and provider_event_id=p_event_id;
  return jsonb_build_object('ok',true,'action','SEALED','sealed_marks',v_mark_count,'batch_id',v_batch.id);
end;
$function$;
