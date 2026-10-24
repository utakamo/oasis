// DOM/HTTP fixtures for the shared conversation-mode control.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname,
    '../../luci-app-oasis/files/luci/www/luci-static/resources/oasis/js/chat-mode.js'), 'utf8');
const settle = async () => { for (let i=0;i<4;i++) await new Promise(setImmediate); };
function fixture(options={}) {
    const env = {enabled:false, available:true, functionCalling:true, generation:0, calls:[], ...options};
    const events = {}, nodes = {};
    for (const id of ['agent-mode-switch','agent-mode-label','agent-mode-notice']) {
        nodes[id] = {attributes:{}, listeners:{}, disabled:true, textContent:'', hidden:false,
            setAttribute(key,value) { this.attributes[key]=value; },
            addEventListener(name,fn) { this.listeners[name]=fn; },
            click() { return this.disabled ? Promise.resolve() : this.listeners.click(); }};
    }
    const window = {OasisChatStrings:env.strings||{}, OasisChatConfig:{csrfToken:'csrf',urls:{getMode:'/get',setMode:'/set'}},
        addEventListener(name,fn) { events[name]=fn; }};
    const snapshot = () => ({status:'OK', enabled:env.enabled, can_enable:env.available && env.functionCalling,
        can_disable:true, token:(env.enabled?'1':'0')+':'+env.generation,
        reason_code:!env.available?'agent_unavailable':env.reasonCode,
        service_reason_code:!env.functionCalling?'function_calling_disabled':undefined});
    vm.runInNewContext(source, {window, URLSearchParams,
        document:{getElementById:id=>nodes[id], addEventListener(name,fn) { events[name]=fn; }},
        fetch:async (url, init={}) => {
            env.calls.push({url,init});
            if (url==='/get') {
                if (env.loadGate) await env.loadGate;
                if (env.loadError) throw new Error('load failed');
                return {ok:!env.httpError, json:async()=>env.invalid?{}:snapshot()};
            }
            assert.equal(url,'/set'); assert.equal(init.method,'POST');
            assert.equal(init.body.get('token'),'csrf');
            if (env.postGate) await env.postGate;
            if (init.body.get('generation') !== snapshot().token || env.reject) {
                return {ok:true,json:async()=>({status:'NG',error:'Reload current mode'})};
            }
            env.enabled=init.body.get('mode')==='agent'; env.generation++;
            if (env.lostResponse) throw new Error('Connection lost');
            return {ok:true,json:async()=>({status:'OK'})};
        }
    });
    events.DOMContentLoaded();
    return Object.assign(env,{button:nodes['agent-mode-switch'],label:nodes['agent-mode-label'],
        notice:nodes['agent-mode-notice'], mode:window.OasisChatMode, events});
}

test('ON/OFF sends POST, CSRF and the expected generation, then reloads persisted state',async()=>{
    const env=fixture(); await settle();
    assert.equal(env.label.textContent,'Agent: OFF');
    await env.button.click();
    assert.equal(env.enabled,true); assert.equal(env.button.attributes['aria-checked'],'true');
    assert.equal(env.calls[1].init.body.get('generation'),'0:0');
    await env.button.click();
    assert.equal(env.enabled,false); assert.equal(env.generation,2);
});
test('Agent absence blocks ON while a saved ON setting can always be turned OFF',async()=>{
    for (const enabled of [false,true]) {
        const env=fixture({enabled,available:false}); await settle();
        assert.equal(env.button.disabled,!enabled);
        assert.match(env.notice.textContent,/oasis-mod-agent/);
        if (enabled) {await env.button.click(); assert.equal(env.enabled,false);}
    }
});
test('Function Calling OFF blocks Agent ON and refreshes automatic OFF after a service change',async()=>{
    const env=fixture({functionCalling:false}); await settle();
    assert.equal(env.button.disabled,true);
    assert.match(env.notice.textContent,/Function Calling disabled/);
    await env.button.click(); assert.equal(env.calls.length,1);
    env.functionCalling=true; env.events.focus(); await settle();
    await env.button.click(); assert.equal(env.enabled,true);
    env.functionCalling=false; env.enabled=false; env.generation++;
    env.events.focus(); await settle();
    assert.equal(env.button.disabled,true); assert.equal(env.label.textContent,'Agent: OFF');
});
test('busy conversations lock the mode control and refresh when finished',async()=>{
    const env=fixture(); await settle(); env.mode.setBusy(true);
    await env.button.click(); assert.equal(env.calls.length,1);
    env.enabled=true; env.generation++; env.mode.setBusy(false); await settle();
    assert.equal(env.button.disabled,false); assert.equal(env.button.attributes['aria-checked'],'true');
});
test('saving locks through POST and reload and prevents duplicate writes',async()=>{
    const env=fixture(); await settle(); let post,load;
    env.postGate=new Promise(resolve=>{post=resolve;});
    env.loadGate=new Promise(resolve=>{load=resolve;});
    const pending=env.button.click();
    assert.equal(env.mode.isSaving(),true); assert.equal(env.button.disabled,true);
    assert.equal(env.button.attributes['aria-checked'],'false');
    await env.button.click(); post(); await settle();
    assert.equal(env.mode.isSaving(),true); load(); await pending;
    assert.equal(env.mode.isSaving(),false); assert.equal(env.enabled,true);
    assert.equal(env.calls.filter(c=>c.init.method==='POST').length,1);
});
test('lost successful POST responses recover the committed mode',async()=>{
    const env=fixture({lostResponse:true}); await settle(); await env.button.click();
    assert.equal(env.button.attributes['aria-checked'],'true');
    assert.equal(env.button.disabled,false); assert.equal(env.notice.textContent,'Connection lost');
});
test('stale generation and rejected saves reload without overwriting another session',async()=>{
    const env=fixture(); await settle(); env.enabled=true; env.generation++;
    await env.button.click(); assert.equal(env.generation,1);
    assert.equal(env.button.attributes['aria-checked'],'true');
    assert.equal(env.notice.textContent,'Reload current mode');
});
for (const failure of ['loadError','httpError','invalid']) {
    test('unknown mode is disabled: '+failure,async()=>{
        const env=fixture({[failure]:true}); await settle();
        assert.equal(env.button.disabled,true); await env.button.click(); assert.equal(env.calls.length,1);
        env[failure]=false; env.events.focus(); await settle(); assert.equal(env.button.disabled,false);
    });
}
test('focus synchronizes CLI changes; localized labels and unavailable reasons are used',async()=>{
    const env=fixture({strings:{agentOn:'Agent：ON',agentOff:'Agent：OFF',agentUnavailable:'Agentをインストールしてください。'}});
    await settle(); assert.equal(env.label.textContent,'Agent：OFF');
    env.enabled=true; env.available=false; env.events.focus(); await settle();
    assert.equal(env.label.textContent,'Agent：ON'); assert.equal(env.notice.textContent,'Agentをインストールしてください。');
});
test('one native switch is shared on desktop and mobile and mode routes require POST to mutate',()=>{
    const root=path.join(__dirname,'../..');
    const template=fs.readFileSync(path.join(root,'luci-app-oasis/files/luci/view/chat.htm'),'utf8');
    assert.equal((template.match(/id="agent-mode-switch"/g)||[]).length,1);
    assert.match(template,/<button[^>]*type="button"[^>]*id="agent-mode-switch"[^>]*role="switch"/);
    assert.ok(template.indexOf('js/chat-mode.js')<template.indexOf('js/chat.js'));
    const controller=fs.readFileSync(path.join(root,'oasis/files/luci/controller/module.lua'),'utf8');
    assert.match(controller,/"set-mode"\}, post\("set_mode"\)/);
    assert.match(controller,/"get-mode"\}, call\("get_mode"\)/);
});
