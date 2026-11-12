import Foundation

let sceneScriptRuntimeServices = #"""
    let storageData={global:{},screens:{}},storageScreen='main',storageDirty=false;
    const jsonCopy=value=>JSON.parse(JSON.stringify(value));
    function storageLocation(location) {
        if(location===undefined||location==='screen')return storageData.screens[storageScreen];
        if(location==='global')return storageData.global;
        throw Error('Unknown localStorage location');
    }
    function storageKey(key) {
        if(typeof key!=='string'||key.length>512)throw Error('localStorage key must be a string of at most 512 characters');
        return key;
    }
    function storageCommit(next) {
        const text=JSON.stringify(next);
        // Count UTF-8 bytes, including non-ASCII strings and surrogate pairs.
        let bytes=0;
        for(const char of text){const n=char.codePointAt(0);bytes+=n<128?1:n<2048?2:n<65536?3:4;}
        if(bytes>100*1024)throw Error('localStorage exceeds the native 100 KiB per-wallpaper limit');
        storageData=JSON.parse(text);storageDirty=true;
    }
    const localStorage=Object.freeze({
        LOCATION_GLOBAL:'global',LOCATION_SCREEN:'screen',
        get(key,location){const map=storageLocation(location);key=storageKey(key);return Object.hasOwn(map,key)?jsonCopy(map[key]):undefined;},
        set(key,value,location){
            const map=storageLocation(location);key=storageKey(key);
            const normalized=JSON.parse(JSON.stringify(value,(_k,item)=>{
                if(typeof item==='function'||typeof item==='symbol'||typeof item==='undefined'||(typeof item==='number'&&!Number.isFinite(item)))throw Error('localStorage supports finite JSON data only');
                return item;
            }));
            const next=jsonCopy(storageData),target=map===storageData.global?next.global:next.screens[storageScreen];
            Object.defineProperty(target,key,{value:normalized,enumerable:true,writable:true,configurable:true});storageCommit(next);
        },
        delete(key,location){
            const map=storageLocation(location);key=storageKey(key);if(!Object.hasOwn(map,key))return false;
            const next=jsonCopy(storageData),target=map===storageData.global?next.global:next.screens[storageScreen];
            delete target[key];storageCommit(next);return true;
        },
        clear(location){const map=storageLocation(location),next=jsonCopy(storageData);if(map===storageData.global)next.global={};else next.screens[storageScreen]={};storageCommit(next);}
    });
    function loadStorage(message) {
        storageScreen=message.storageScreen || 'main';
        storageData=jsonCopy(message.storage || {global:{},screens:{}});
        if(!storageData.screens[storageScreen])storageData.screens[storageScreen]={};
    }

    const timers=new Set();
    function scheduleTimer(callback,delay=0,repeat=false) {
        if(typeof callback!=='function'||typeof delay!=='number'||!Number.isFinite(delay)||delay<0||delay>86400000)throw Error('Invalid timer callback or delay (0...86400000 ms)');
        if(timers.size>=256)throw Error('SceneScript exceeds 256 active timers');
        const timer={callback,binding:timelineBinding,delay:delay/1000,due:engine.runtime+delay/1000,repeat};
        timers.add(timer);return ()=>{timers.delete(timer);};
    }
    engine.setTimeout=(callback,delay)=>scheduleTimer(callback,delay,false);
    engine.setInterval=(callback,delay)=>scheduleTimer(callback,delay,true);
    function updateTimers() {
        // Snapshotting prevents recursive zero-delay callbacks from starving
        // rendering; missed interval ticks coalesce to one per delivered frame.
        for(const timer of [...timers]) {
            if(!timers.has(timer)||timer.due>engine.runtime)continue;
            if(timer.repeat)timer.due=engine.runtime+timer.delay;else timers.delete(timer);
            try{withTimelineBinding(timer.binding,timer.callback);}catch(error){timers.delete(timer);fail('timer',error);}
        }
    }

    function layerWorldMatrix(record,seen=new Set()) {
        if(seen.has(record.id)||seen.size>=512)throw Error('Cyclic or over-depth layer transform');
        seen.add(record.id);
        const {origin:o,angles:a,scale:s}=record.state;
        const x=a.x*Math.PI/180,y=a.y*Math.PI/180,z=a.z*Math.PI/180;
        const cx=Math.cos(x),sx=Math.sin(x),cy=Math.cos(y),sy=Math.sin(y),cz=Math.cos(z),sz=Math.sin(z);
        const local=[cy*cz*s.x,cy*sz*s.x,-sy*s.x,0,
          (sx*sy*cz-cx*sz)*s.y,(sx*sy*sz+cx*cz)*s.y,sx*cy*s.y,0,
          (cx*sy*cz+sx*sz)*s.z,(cx*sy*sz-sx*cz)*s.z,cx*cy*s.z,0,o.x,o.y,o.z,1];
        if(!local.every(Number.isFinite))throw Error('Non-finite layer transform');
        if(record.parentID===undefined)return local;
        const parents=layers.filter(layer=>layer.id===record.parentID);
        if(parents.length!==1)throw Error('Missing or ambiguous transform parent');
        const parent=layerWorldMatrix(parents[0],seen),world=Array(16).fill(0);
        for(let c=0;c<4;c++)for(let r=0;r<4;r++)for(let k=0;k<4;k++)world[c*4+r]+=parent[k*4+r]*local[c*4+k];
        return world;
    }
    // Constants allow scripts to initialize their own idle state. This host
    // does not yet publish system media events or synthesize active playback.
    const MediaPlaybackEvent=Object.freeze({PLAYBACK_STOPPED:0,PLAYBACK_PLAYING:1,PLAYBACK_PAUSED:2});
"""#
