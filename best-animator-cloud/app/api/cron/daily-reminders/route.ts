import {NextRequest,NextResponse} from 'next/server';
import {createClient} from '@supabase/supabase-js';
export const dynamic='force-dynamic';
export const maxDuration=60;

type OrderRow={id:string;client_id:string;program:string;event_date:string;start_time:string;duration_minutes:number;location:string;team_id:string|null;status:string};
type Recipient={id:string;name:string;chat_id:string;role:'manager'|'animator';team_id:string|null};

export async function GET(req:NextRequest){
 const cronSecret=process.env.CRON_SECRET;
 if(!cronSecret || req.headers.get('authorization')!==`Bearer ${cronSecret}`) return NextResponse.json({error:'Unauthorized'},{status:401});
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL;
 const key=process.env.SUPABASE_SERVICE_ROLE_KEY;
 const botToken=process.env.TELEGRAM_BOT_TOKEN;
 if(!url||!key||!botToken)return NextResponse.json({error:'Missing server configuration'},{status:500});
 const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const dateParts=new Intl.DateTimeFormat('en-US',{timeZone:'Asia/Tashkent',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date());
 const getPart=(type:string)=>dateParts.find(p=>p.type===type)?.value||'';
 const today=`${getPart('year')}-${getPart('month')}-${getPart('day')}`;
 const [{data:orders,error:oErr},{data:recipients,error:rErr},{data:clients,error:cErr},{data:teams,error:tErr},{data:chars,error:chErr},{data:assignments,error:aErr}]=await Promise.all([
  db.from('orders').select('id,client_id,program,event_date,start_time,duration_minutes,location,team_id,status').eq('event_date',today).in('status',['pending','confirmed']),
  db.from('telegram_recipients').select('id,name,chat_id,role,team_id').eq('is_active',true),
  db.from('clients').select('id,name'),
  db.from('teams').select('id,name'),
  db.from('characters').select('id,name'),
  db.from('order_characters').select('order_id,character_id')
 ]);
 if(oErr||rErr||cErr||tErr||chErr||aErr){console.error('Reminder DB read failed',oErr||rErr||cErr||tErr||chErr||aErr);return NextResponse.json({error:'Database read failed'},{status:500})}
 const clientById=new Map((clients||[]).map(c=>[c.id,c.name]));
 const teamById=new Map((teams||[]).map(t=>[t.id,t.name]));
 const characterById=new Map((chars||[]).map(c=>[c.id,c.name]));
 let sent=0,skipped=0,failed=0;
 for(const o of (orders||[]) as OrderRow[]){
  for(const r of (recipients||[]) as Recipient[]){
   if(r.role==='animator' && (!o.team_id || o.team_id!==r.team_id))continue;
   // Claim reminder before Telegram send, preserving idempotence across overlapping cron invocations.
   const {error:claimError}=await db.from('telegram_delivery_log').insert({notification_date:today,order_id:o.id,recipient_id:r.id});
   if(claimError){if(claimError.code==='23505'){skipped++;continue}console.error('Reminder claim error',claimError);failed++;continue}
   const names=(assignments||[]).filter(a=>a.order_id===o.id).map(a=>characterById.get(a.character_id)).filter(Boolean).join(', ');
   const message=[`🎉 BEST Animator · Сегодня, ${today}`,`⏰ ${String(o.start_time).slice(0,5)} · ${o.duration_minutes} мин`,`🎭 ${o.program}`,`📍 ${o.location||'Место не указано'}`,`👥 ${o.team_id?teamById.get(o.team_id)||'Команда':'Команда не назначена'}`,`✨ ${names||'Персонажи не назначены'}`, ...(r.role==='manager'?[`👤 Клиент: ${clientById.get(o.client_id)||'Клиент'}`]:[]),`📌 Заказ: ${o.id.slice(0,8)}`].join('\n');
   try{
    const res=await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat_id:r.chat_id,text:message,disable_web_page_preview:true}),signal:AbortSignal.timeout(8000)});
    if(!res.ok)throw new Error(`Telegram HTTP ${res.status}`);
    sent++;
   }catch(err){failed++;console.error('Telegram send failed',err);const {error:cleanup}=await db.from('telegram_delivery_log').delete().eq('notification_date',today).eq('order_id',o.id).eq('recipient_id',r.id);if(cleanup)console.error('Reminder claim cleanup failed',cleanup)}
  }
 }
 return NextResponse.json({ok:failed===0,date:today,sent,skipped,failed},{status:failed?502:200});
}
