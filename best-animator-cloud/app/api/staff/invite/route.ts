import {NextRequest,NextResponse} from 'next/server';
import {createClient} from '@supabase/supabase-js';

// The service-role key is server-only; NEVER prefix it with NEXT_PUBLIC_.
export async function POST(request:NextRequest){
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL;
 const anon=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
 const serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!url||!anon||!serviceKey)return NextResponse.json({error:'STAFF_INVITE_NOT_CONFIGURED'}, {status:503});
 const token=request.headers.get('authorization')?.match(/^Bearer (.+)$/i)?.[1];
 if(!token)return NextResponse.json({error:'UNAUTHORIZED'},{status:401});
 const publicClient=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:{user},error:authError}=await publicClient.auth.getUser(token);
 if(authError||!user)return NextResponse.json({error:'UNAUTHORIZED'},{status:401});
 const admin=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:profile,error:roleError}=await admin.from('staff_profiles').select('role').eq('user_id',user.id).maybeSingle();
 if(roleError||profile?.role!=='owner')return NextResponse.json({error:'FORBIDDEN_OWNER_ONLY'},{status:403});
 let body:unknown;
 try{body=await request.json();}catch{return NextResponse.json({error:'INVALID_JSON'},{status:400})}
 if(!body||typeof body!=='object')return NextResponse.json({error:'INVALID_PAYLOAD'},{status:400});
 const input=body as Record<string,unknown>;
 const email=typeof input.email==='string'?input.email.trim().toLowerCase():'';
 const name=typeof input.name==='string'?input.name.trim():'';
 if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||email.length>254||name.length<2||name.length>80)
   return NextResponse.json({error:'INVALID_EMAIL_OR_NAME'},{status:400});
 // Owner can invite a manager, but cannot create another owner via this endpoint.
 const redirect=process.env.CRM_PUBLIC_URL?.trim();
 if(redirect){
  try{
   const target=new URL(redirect);
   if(target.protocol!=='https:'||!(target.hostname.endsWith('.vercel.app')||target.hostname==='crm.doublebubbleshow.uz')||target.username||target.password)
     return NextResponse.json({error:'INVALID_CRM_PUBLIC_URL'},{status:503});
  }catch{return NextResponse.json({error:'INVALID_CRM_PUBLIC_URL'},{status:503})}
 }
 const invite=await admin.auth.admin.inviteUserByEmail(email,{
    data:{display_name:name},...(redirect?{redirectTo:redirect}:{})
 });
 if(invite.error||!invite.data.user)return NextResponse.json({error:invite.error?.message||'INVITE_FAILED'},{status:400});
 const id=invite.data.user.id;
 const {data:existing,error:existingError}=await admin.from('staff_profiles').select('role').eq('user_id',id).maybeSingle();
 if(existingError)return NextResponse.json({error:'PROFILE_CHECK_FAILED'},{status:500});
 if(existing)return NextResponse.json({error:'STAFF_ALREADY_EXISTS'},{status:409});
 const save=await admin.from('staff_profiles').insert({user_id:id,display_name:name,role:'manager'});
 if(save.error)return NextResponse.json({error:'INVITED_BUT_PROFILE_FAILED: '+save.error.message},{status:500});
 const defaults=['orders.create','orders.update_status','execution.update',
   'finance.view_payments','finance.record_payment','finance.view_expenses','finance.create_expense','finance.edit_expense','audit.view'];
 const permissions=await admin.from('staff_permissions').upsert(defaults.map(permission=>({user_id:id,permission,granted_by:user.id})),{onConflict:'user_id,permission',ignoreDuplicates:true});
 if(permissions.error)return NextResponse.json({error:'INVITED_BUT_PERMISSIONS_FAILED: '+permissions.error.message},{status:500});
 return NextResponse.json({ok:true,user_id:id,message:'Приглашение отправлено на email сотрудника'});
}