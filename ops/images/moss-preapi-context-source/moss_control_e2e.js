const {chromium}=require('playwright-core');
(async()=>{
  const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME,args:['--no-sandbox']});
  const page=await browser.newPage();
  const errors=[]; const steerResponses=[]; let runsCalls=0;
  page.on('pageerror',e=>errors.push(String(e)));
  page.on('request',r=>{if(r.url().includes('/v1/runs')) runsCalls++;});
  await page.goto('http://127.0.0.1:8787/',{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>typeof newSession==='function'&&typeof send==='function'&&document.getElementById('msg'),null,{timeout:30000});
  await page.waitForTimeout(2000);
  await page.evaluate(async()=>{await newSession();});
  await page.waitForFunction(()=>S.session&&S.session.session_id,null,{timeout:30000});
  const sid=await page.evaluate(()=>S.session.session_id);
  console.log(JSON.stringify({checkpoint:'session_created',sid}));
  await page.locator('#msg').fill('Write the integers from 1 through 3000, one per line, with no omissions. This is a streaming control test.');
  await page.evaluate(()=>send());
  await page.waitForFunction(()=>S.busy&&S.activeStreamId,null,{timeout:60000});
  const stream1=await page.evaluate(()=>S.activeStreamId);
  await page.locator('#msg').fill('/queue QUEUE_MOSS_MARKER');
  await page.evaluate(()=>send());
  await page.waitForTimeout(300);
  const qBefore=await page.evaluate(sid=>_getSessionQueue(sid).map(x=>x.text),sid);
  const deadline=Date.now()+30000;
  while(Date.now()<deadline){
    const probe=await page.evaluate(async({sid,stream1})=>{
      if(!S.busy||S.activeStreamId!==stream1) return {ended:true};
      const r=await fetch('/api/chat/steer',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({session_id:sid,text:'STEER_MOSS_MARKER'})});
      let body=null; try{body=await r.json();}catch{}
      return {status:r.status,body};
    },{sid,stream1});
    if(probe.ended) break;
    steerResponses.push({status:probe.status,body:probe.body});
    if(steerResponses.length>20) steerResponses.shift();
    if(probe.status===200&&probe.body&&probe.body.accepted===true&&probe.body.stream_id===stream1){
      console.log(JSON.stringify({checkpoint:'steer_accepted',sid,stream1,qBefore,probe,runsCalls,errors}));
      break;
    }
    await page.waitForTimeout(200);
  }
  const stateAfter=await page.evaluate(sid=>({busy:S.busy,stream:S.activeStreamId,queue:_getSessionQueue(sid).map(x=>x.text)}),sid);
  const accepted=steerResponses.some(x=>x.status===200&&x.body&&x.body.accepted===true&&x.body.stream_id===stream1);
  const controlPass=stateAfter.busy&&qBefore.includes('QUEUE_MOSS_MARKER')&&accepted&&stateAfter.stream===stream1&&stateAfter.queue.includes('QUEUE_MOSS_MARKER')&&runsCalls===0&&errors.length===0;
  console.log(JSON.stringify({checkpoint:'control_complete',sid,stream1,qBefore,steerResponses,stateAfter,runsCalls,errors,controlPass}));
  if(!controlPass){await browser.close();process.exit(2);}
  await page.evaluate(sid=>{const q=_getSessionQueue(sid);q.splice(0,q.length);_persistSessionQueueStorage(sid,q);},sid);
  await page.evaluate(async()=>{
    if(typeof cancelStream!=='function') throw new Error('cancelStream unavailable');
    await cancelStream();
  });
  await page.waitForFunction(()=>!S.busy,null,{timeout:30000});
  const frontendObservedIdle=true;
  await page.waitForTimeout(500);
  const cancelSession=await (await page.request.get(`http://127.0.0.1:8787/api/session?session_id=${encodeURIComponent(sid)}`)).json();
  const cancelRecord=cancelSession?.session??cancelSession;
  const hasActiveStreamField=!!cancelRecord&&Object.prototype.hasOwnProperty.call(cancelRecord,'active_stream_id');
  const backendActiveStream=hasActiveStreamField?cancelRecord.active_stream_id:undefined;
  const cancelMessageCount=Array.isArray(cancelRecord?.messages)?cancelRecord.messages.length:null;
  const backendStreamCleared=hasActiveStreamField&&backendActiveStream===null;
  const cancelled=frontendObservedIdle&&backendStreamCleared&&Number.isInteger(cancelMessageCount)&&cancelMessageCount>=2;
  if(!cancelled) throw new Error(`cancel gate failed: frontendObservedIdle=${frontendObservedIdle} hasActiveStreamField=${hasActiveStreamField} backendActiveStream=${backendActiveStream} messageCount=${cancelMessageCount}`);
  await page.reload({waitUntil:'domcontentloaded'});
  await page.waitForTimeout(2000);
  let preCompactRecord=null;
  for(const [prompt,targetCount] of [['Reply exactly SECOND_TURN_OK',4],['Reply exactly THIRD_TURN_OK',6]]){
    await page.locator('#msg').fill(prompt);
    await page.evaluate(()=>send());
    const turnDeadline=Date.now()+60000;
    while(Date.now()<turnDeadline){
      const payload=await (await page.request.get(`http://127.0.0.1:8787/api/session?session_id=${encodeURIComponent(sid)}`)).json();
      preCompactRecord=payload?.session??payload;
      const count=Array.isArray(preCompactRecord?.messages)?preCompactRecord.messages.length:0;
      const hasStream=!!preCompactRecord&&Object.prototype.hasOwnProperty.call(preCompactRecord,'active_stream_id');
      if(count>=targetCount&&hasStream&&preCompactRecord.active_stream_id===null) break;
      await page.waitForTimeout(250);
    }
    const turnMessages=Array.isArray(preCompactRecord?.messages)?preCompactRecord.messages.length:0;
    if(turnMessages<targetCount||!Object.prototype.hasOwnProperty.call(preCompactRecord||{},'active_stream_id')||preCompactRecord.active_stream_id!==null) throw new Error(`follow-up turn did not persist terminally: target=${targetCount} messages=${turnMessages} stream=${preCompactRecord?.active_stream_id}`);
    await page.waitForFunction(()=>!S.busy,null,{timeout:10000});
  }
  const preCompactMessages=Array.isArray(preCompactRecord?.messages)?preCompactRecord.messages.length:0;
  await page.locator('#msg').fill('/compact');
  await page.evaluate(()=>send());
  const compactStatuses=[];
  let compactDone=false;
  const compactDeadline=Date.now()+60000;
  while(Date.now()<compactDeadline){
    const response=await page.request.get(`http://127.0.0.1:8787/api/session/compress/status?session_id=${encodeURIComponent(sid)}`);
    const data=await response.json();
    compactStatuses.push(data?.status??null);
    if(data?.status==='done'){compactDone=true;break;}
    if(data?.status==='error') throw new Error(`compact failed: ${data.error||'unknown error'}`);
    await page.waitForTimeout(250);
  }
  if(!compactDone) throw new Error(`compact did not reach done: ${JSON.stringify(compactStatuses.slice(-12))}`);
  await page.waitForFunction(()=>!S.busy,null,{timeout:10000});
  const persisted=await (await page.request.get(`http://127.0.0.1:8787/api/session?session_id=${encodeURIComponent(sid)}`)).json();
  const persistedMessages=persisted?.session?.messages?.length??persisted?.messages?.length??null;
  if(!Number.isInteger(persistedMessages)||persistedMessages<2) throw new Error(`unexpected persisted message count: ${persistedMessages}`);
  console.log(JSON.stringify({checkpoint:'lifecycle_complete',sid,cancelled,cancelMessageCount,preCompactMessages,compactCompleted:true,compactStatuses,persistedMessages}));
  await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
