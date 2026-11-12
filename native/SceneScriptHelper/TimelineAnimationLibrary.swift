import Foundation

// Playback control only. Curve sampling remains in the native renderer.
let sceneScriptTimelineAnimationLibrary = #"""
    const timelineAnimations = new Map();
    const timelineCommands = [];
    let timelineCommandOverflow = false;
    let timelineBinding = null, timelineModuleLoading = false;
    function withTimelineBinding(binding,callback) {
        const previous=timelineBinding;timelineBinding=binding;
        try{return callback();}finally{timelineBinding=previous;}
    }
    const timelinePropertyKey=path=>path.split('/').pop().replace(/~1/g,'/').replace(/~0/g,'~');
    const animationEventCounts = {received:0,calls:0};
    function timelineAnimation(metadata) {
        const {fps,length,mode,frameDuration,duration}=metadata;
        if(!Number.isFinite(fps)||fps<=0||fps>1000||!Number.isInteger(length)||length<=0||length>1e9||
           !['single','mirror','loop'].includes(mode)||!Number.isFinite(frameDuration)||frameDuration<=0||
           !Number.isFinite(duration)||duration<=0||Math.fround(frameDuration)!==frameDuration||
           Math.fround(duration)!==duration)throw Error('Invalid timeline metadata');
        let state={time:0,rate:1,paused:metadata.startpaused,completed:false,reversed:false},alive=true;
        function emit(action,value) {
            if(!alive)throw Error('Timeline owner has been removed');
            if(timelineCommands.length>=256) {
                timelineCommandOverflow=true;
                throw Error('Timeline command batch exceeds 256 operations');
            }
            const command={ordinal:timelineCommands.length,path:metadata.path,action};
            if(value!==undefined)command.value=value;
            timelineCommands.push(command);
        }
        const view=Object.freeze({
            get fps(){return Math.fround(1/frameDuration);},get frameCount(){return length;},get duration(){return duration;},
            get name(){return metadata.name;},get rate(){return state.rate;},
            set rate(value){
                if(typeof value!=='number'||!Number.isFinite(value)||Math.abs(value)>100)throw Error('Timeline rate must be finite and within -100...100');
                emit('rate',value);state.rate=Math.fround(value);
            },
            play(){
                emit('play');if(state.completed)state.time=0;
                state.paused=false;state.completed=false;
            },
            pause(){emit('pause');state.paused=true;},
            stop(){emit('stop');state.time=0;state.paused=true;state.completed=false;state.reversed=false;},
            isPlaying(){return !state.paused&&!state.completed;},
            getFrame(){return Math.fround(state.time/frameDuration);},
            setFrame(value){
                if(typeof value!=='number'||!Number.isFinite(value)||value<0||value>length)throw Error('Timeline frame must be within 0...frameCount');
                const time=Math.fround(Math.fround(value)*frameDuration);
                if(!Number.isFinite(time))throw Error('Timeline frame produces non-finite time');
                emit('setFrame',value);state.time=time;
            }
        });
        // A script can observe its own commands immediately, but only the next
        // host snapshot corrects this local view; it never advances a clock.
        return {metadata,view,snapshot:()=>({...state}),retire:()=>{alive=false;},install:value=>{state={...value};}};
    }
    function loadTimelineAnimations(metadata) {
        if(!Array.isArray(metadata)||metadata.length>128)throw Error('Invalid timeline list');
        let eventCount=0,eventBytes=0;
        for(const item of metadata) {
            if(typeof item.path!=='string'||item.path.length>4096||timelineAnimations.has(item.path)||
               typeof item.objectID!=='string'||typeof item.ownerPath!=='string'||typeof item.layerProperty!=='string'||
               typeof item.name!=='string'||item.name.length>1024||typeof item.startpaused!=='boolean')throw Error('Invalid timeline identity');
            const events=item.events ?? [];
            if(!Array.isArray(events)||events.length>256)throw Error('Invalid timeline events');
            eventCount+=events.length;
            for(const text of events) {
                if(typeof text!=='string'||text.length>4096)throw Error('Invalid timeline event JSON');
                eventBytes+=text.length;
                const event=JSON.parse(text);
                if(!event||typeof event!=='object'||Array.isArray(event)||typeof event.name!=='string'||
                   event.name.length>1024||!Number.isFinite(event.frame)||Math.abs(event.frame)>1e9)throw Error('Invalid timeline event');
            }
            if(eventCount>4096||eventBytes>256*1024)throw Error('Timeline event budget exceeded');
            timelineAnimations.set(item.path,timelineAnimation({...item,events,propertyKey:timelinePropertyKey(item.path)}));
        }
    }
    function prepareAnimationEvents(events) {
        if(!Array.isArray(events)||events.length>128)throw Error('Invalid animation event batch');
        return events.map(event=>{
            const entry=timelineAnimations.get(event?.path),index=event?.eventIndex;
            if(!entry||!Number.isInteger(index)||index<0||index>=entry.metadata.events.length)throw Error('Unknown animation event');
            return {objectID:entry.metadata.objectID,json:entry.metadata.events[index]};
        });
    }
    function deliverAnimationEvents(events) {
        for(const event of events) {
            animationEventCounts.received=Math.min(1e9,animationEventCounts.received+1);
            if(!event.objectID)continue;
            for(const binding of bindings)if(binding.objectID===event.objectID&&!binding.disabled&&typeof binding.exports.animationEvent==='function') {
                animationEventCounts.calls=Math.min(1e9,animationEventCounts.calls+1);
                // Each binding owns a fresh JSON payload. A listener cannot
                // change the event observed by another script on this layer.
                invoke(binding,'animationEvent',JSON.parse(event.json),true);
            }
        }
    }
    function installTimelineStates(states,partial=false) {
        if(!states||typeof states!=='object'||Array.isArray(states)||(partial?Object.keys(states).length>timelineAnimations.size:Object.keys(states).length!==timelineAnimations.size))throw Error('Incomplete native timeline state');
        const prepared=[];
        for(const [path,value] of Object.entries(states)) {
            const entry=timelineAnimations.get(path);
            if(!entry||!value||typeof value!=='object'||Array.isArray(value)||
               !Number.isFinite(value.time)||Math.fround(value.time)!==value.time||
               !Number.isFinite(value.rate)||Math.abs(value.rate)>100||Math.fround(value.rate)!==value.rate||
               typeof value.paused!=='boolean'||typeof value.completed!=='boolean'||typeof value.reversed!=='boolean')throw Error('Invalid native timeline state');
            prepared.push([entry,{time:value.time,rate:value.rate,paused:value.paused,completed:value.completed,reversed:value.reversed}]);
        }
        for(const [entry,value] of prepared)entry.install(value);
    }
    function namedTimeline(name,objectID,ownerPath) {
        if(typeof name!=='string'||name.length>1024)throw Error('Timeline name must be a bounded string');
        const matches=[...timelineAnimations.values()].filter(entry=>
            (objectID===undefined||entry.metadata.objectID===objectID)&&
            (ownerPath!==undefined?entry.metadata.ownerPath===ownerPath:objectID===undefined||!!entry.metadata.layerProperty)&&
            (entry.metadata.name===name||entry.metadata.propertyKey===name));
        if(matches.length>1)throw Error('Ambiguous timeline name: '+name);
        return matches[0]?.view ?? null;
    }
    function ownerTimeline(name,objectID,ownerPath) {
        // OwnerObject uses the current callback's property key for an omitted,
        // empty or non-string name, but still scopes lookup to the receiver.
        const query=typeof name==='string'&&name.length?name:
            timelineBinding?timelinePropertyKey(timelineBinding.key):'';
        return namedTimeline(query,objectID,ownerPath);
    }
    function sceneTimeline(name) {
        if(timelineModuleLoading)throw Error('getAnimation cannot be called from global scope');
        if(typeof name!=='string')return undefined;
        return namedTimeline(name);
    }
    function propertyObject(binding,owner) {
        const ownerPath=binding.key.split('/').slice(1,-1).join('/');
        return new Proxy(Object.create(null),{
            get:(_,key)=>{
                if(key==='getAnimation')return name=>ownerTimeline(name,binding.objectID,ownerPath);
                if(binding.modelProperty) {
                    const record=binding.modelProperty.record;
                    if(!record?.alive)throw Error('Animation layer has been removed');
                    if(key in record.view)return record.view[key];
                    throw Error('Unsupported animation layer property: '+String(key));
                }
                if(binding.layerProperty&&owner)return owner[key];
                if(binding.effect)return binding.effect.view[key];
                if(binding.material)return binding.material.owner.view[key];
                if(key==='visible' && /^\/objects\/\d+\/effects\/\d+\/visible$/.test(binding.key))return binding.value;
                throw Error('Unsupported thisObject property: '+String(key));
            },
            set:(_,key,value)=>{
                if(binding.modelProperty){writeModelProperty(binding.modelProperty.record,key,value);return true;}
                if(binding.layerProperty&&owner){owner[key]=value;return true;}
                if(binding.effect){binding.effect.view[key]=value;return true;}
                if(binding.material){binding.material.owner.view[key]=value;return true;}
                if(key==='visible' && /^\/objects\/\d+\/effects\/\d+\/visible$/.test(binding.key)) {
                    if(typeof value!=='boolean')throw Error('Effect visibility must be boolean');
                    binding.value=value;if(binding.timeline)binding.timelineOverride=true;return true;
                }
                throw Error('Unsupported thisObject write: '+String(key));
            }
        });
    }
    function updateTimelineInputs(values) {
        for(const [path,value] of Object.entries(values || {})) {
            const entry=timelineAnimations.get(path);
            if(!entry)continue;
            updateSceneTimeline(path,value);
            const modelProperty=modelPropertyAt(path,entry.metadata.objectID);
            if(modelProperty?.record?.alive&&!modelProperty.record.state.overrides.includes(modelProperty.property)) {
                modelProperty.record.state[modelProperty.property]=checkedModelProperty(modelProperty.property,value);
            }
            const material=materialProperties.get(path);
            if(material&&!material.overridden)material.value=materialComponents(value,material.value.length);
            const binding=bindings.find(item=>item.key===path);
            if(binding) {
                // Keep the last explicit script return separate from host curve
                // samples; an event-only binding has no explicit override.
                binding.timelineSample=copy(coerce(value,binding.value));
                if(!binding.timelineOverride)binding.value=copy(binding.timelineSample);
            }
            const {objectID,layerProperty}=entry.metadata;
            const layer=layers.find(item=>item.id===objectID);
            if(layerProperty&&layer&&Object.hasOwn(layer.state,layerProperty)&&!Object.hasOwn(layer.changes,layerProperty)) {
                const effective=binding?.timelineOverride?binding.value:value;
                layer.state[layerProperty]=copy(coerce(effective,layer.state[layerProperty]));
            }
        }
    }
"""#
