import Foundation

// Model animation handles mirror native state; only ordered commands cross
// back to Swift. Author JavaScript never advances or replaces native clocks.
let sceneScriptModelAnimationLibrary = #"""
    const models=new Map(),modelViews=new WeakMap(),modelCommands=[];
    const modelEventCounts={received:0,calls:0,markers:0,markerCalls:0};
    let modelSerial=0,modelCommandOverflow=false,modelCallbackCount=0;
    const modelMethods=['getAnimationLayerCount','getAnimationLayer','createAnimationLayer','destroyAnimationLayer','playSingleAnimation'];
    const modelNumbers={rate:[-100,100],blend:[0,1],blendtime:[0,3600]};
    const modelFlags=['visible','additive','blendin','blendout'];
    function checkedModelProperty(key,value) {
        if(Object.hasOwn(modelNumbers,key))return modelFloat(value,...modelNumbers[key],key);
        if(!modelFlags.includes(key)||typeof value!=='boolean')throw Error('Invalid model animation property '+key);
        return value;
    }
    function modelPropertyAt(path,id) {
        const match=/^\/objects\/\d+\/animationlayers\/(\d+)\/([^/]+)$/.exec(path);
        if(!match)return null;
        const model=models.get(id);
        // Puppet layers have their own property owners; this model extension
        // must not consume or reject their existing timeline traffic.
        if(!model)return null;
        const key=model.authoredKeys[Number(match[1])],property=match[2];
        if(!key||(!Object.hasOwn(modelNumbers,property)&&!modelFlags.includes(property)))throw Error('Unknown authored animation property');
        return {model,key,property,get record(){return model.records.get(key);}};
    }
    function writeModelProperty(record,key,value) {
        if(!record?.alive)throw Error('Animation layer has been removed');
        value=checkedModelProperty(key,value);
        modelCommand(record.model.id,record.state.key,key,{value});
        record.state[key]=value;
        if(key==='rate')record.state.clock.rate=value;
        if(!record.state.overrides.includes(key))record.state.overrides.push(key);
        for(const binding of bindings)if(binding.modelProperty?.model===record.model&&binding.modelProperty.key===record.state.key&&binding.modelProperty.property===key) {
            binding.value=value;if(binding.timeline)binding.timelineOverride=true;
        }
    }
    function modelCommand(id,key,action,extra={}) {
        if(modelCommands.length>=256){modelCommandOverflow=true;throw Error('Model animation command batch exceeds 256 operations');}
        modelCommands.push({ordinal:modelCommands.length,id,key,action,...extra});
    }
    function modelFloat(value,low,high,label) {
        if(typeof value!=='number'||!Number.isFinite(value)||value<low||value>high)throw Error('Invalid model animation '+label);
        return Math.fround(value);
    }
    function modelClock(value) {
        if(!value||!Number.isFinite(value.time)||Math.fround(value.time)!==value.time||
           !Number.isFinite(value.rate)||Math.abs(value.rate)>100||Math.fround(value.rate)!==value.rate||
           typeof value.paused!=='boolean'||typeof value.completed!=='boolean'||typeof value.reversed!=='boolean')throw Error('Invalid native model clock');
        return {...value};
    }
    function modelRecord(model,state) {
        const record={model,alive:true,state,callbacks:[]};
        const clip=model.clips.get(state.clip);
        function active(){if(!record.alive)throw Error('Animation layer has been removed');}
        const view=Object.freeze({
            get fps(){return Math.fround(1/clip.frameDuration);},get frameCount(){return clip.frameCount;},get duration(){return clip.duration;},get name(){return record.state.name;},
            get rate(){return record.state.rate;},set rate(value){writeModelProperty(record,'rate',value);},
            get blend(){return record.state.blend;},set blend(value){writeModelProperty(record,'blend',value);},
            get visible(){return record.state.visible;},set visible(value){writeModelProperty(record,'visible',value);},
            get additive(){return record.state.additive;},set additive(value){writeModelProperty(record,'additive',value);},
            get blendin(){return record.state.blendin;},set blendin(value){writeModelProperty(record,'blendin',value);},
            get blendout(){return record.state.blendout;},set blendout(value){writeModelProperty(record,'blendout',value);},
            get blendtime(){return record.state.blendtime;},set blendtime(value){writeModelProperty(record,'blendtime',value);},
            play(){active();modelCommand(model.id,state.key,'play');if(record.state.clock.completed)record.state.clock.time=0;record.state.clock.paused=false;record.state.clock.completed=false;},
            pause(){active();modelCommand(model.id,state.key,'pause');record.state.clock.paused=true;},
            stop(){active();modelCommand(model.id,state.key,'stop');record.state.clock={...record.state.clock,time:0,paused:true,completed:false,reversed:false};},
            isPlaying(){return record.alive&&!record.state.clock.paused&&!record.state.clock.completed;},
            getFrame(){return Math.fround(record.state.clock.time/clip.frameDuration);},
            setFrame(value){active();value=modelFloat(value,0,clip.frameCount,'frame');modelCommand(model.id,state.key,'setFrame',{value});record.state.clock.time=Math.fround(value*clip.frameDuration);},
            addEndedCallback(callback){
                active();if(typeof callback!=='function'||record.callbacks.length>=32||modelCallbackCount>=4096)throw Error('Invalid animation callback or callback budget exceeded');
                record.callbacks.push({callback,binding:timelineBinding});modelCallbackCount++;
            }
        });
        record.view=view;modelViews.set(view,record);return record;
    }
    function loadModels(metadata) {
        if(!metadata||typeof metadata!=='object'||Array.isArray(metadata)||Object.keys(metadata).length>256)throw Error('Invalid model animation metadata');
        for(const [id,value] of Object.entries(metadata)) {
            if(id.length>1024||!Array.isArray(value.clips)||value.clips.length>4096)throw Error('Invalid model animation inventory');
            const clips=new Map();
            for(const clip of value.clips) {
                const initialFrame=clip.initialFrame??0;
                if(typeof clip.id!=='string'||clip.id.length>32||clips.has(clip.id)||typeof clip.name!=='string'||clip.name.length>4096||
                   !Number.isFinite(clip.fps)||clip.fps<=0||clip.fps>1000||!Number.isInteger(clip.frameCount)||clip.frameCount<1||clip.frameCount>1e7||
                   !Number.isFinite(clip.frameDuration)||clip.frameDuration<=0||!Number.isFinite(clip.duration)||clip.duration<=0||
                   !Number.isInteger(initialFrame)||initialFrame<0||initialFrame>clip.frameCount||!Number.isFinite(Math.fround(initialFrame*clip.frameDuration))||
                   !['loop','mirror','single'].includes(clip.mode))throw Error('Invalid model animation clip');
                const events=clip.events??[];
                if(!Array.isArray(events)||events.length>256)throw Error('Invalid model animation markers');
                for(const text of events) {
                    if(typeof text!=='string'||text.length>4096)throw Error('Invalid model marker JSON');
                    const payload=JSON.parse(text);
                    if(!payload||typeof payload!=='object'||Array.isArray(payload)||typeof payload.name!=='string'||payload.name.length>1024)throw Error('Invalid model marker payload');
                }
                clips.set(clip.id,{...clip,initialFrame,events});
            }
            const authoredKeys=value.authoredKeys??[];
            if(!Array.isArray(authoredKeys)||authoredKeys.length>32||new Set(authoredKeys).size!==authoredKeys.length||authoredKeys.some(key=>typeof key!=='string'||key.length>128))throw Error('Invalid authored model layer identities');
            if(value.rootMotion!==undefined&&typeof value.rootMotion!=='boolean')throw Error('Invalid root motion capability');
            models.set(id,{id,clips,authoredKeys,rootMotion:value.rootMotion===true,records:new Map(),order:[]});
        }
    }
    function isModelTransform(id,key) { return models.get(id)?.rootMotion===true&&['origin','angles','rootmotion'].includes(key); }
    function publishModelTransform(layer,key,value) {
        if(isModelTransform(layer.id,key))modelCommand(layer.id,key,'transform',{value:copy(value)});
    }
    function installModelTransforms(values) {
        if(!values||typeof values!=='object'||Array.isArray(values)||Object.keys(values).length>256)throw Error('Invalid model transform snapshot');
        const prepared=[];
        for(const [id,value] of Object.entries(values)) {
            const layer=layers.find(layer=>layer.id===id);
            if(!layer||models.get(id)?.rootMotion!==true||!value||Object.keys(value).sort().join(',')!=='angles,origin,rootmotion'||typeof value.rootmotion!=='boolean')throw Error('Invalid model transform owner');
            const state={rootmotion:value.rootmotion};
            for(const key of ['origin','angles']) {
                if(!Array.isArray(value[key])||value[key].length!==3||!value[key].every(Number.isFinite))throw Error('Invalid native model vector');
                state[key]=initial(value[key],key);
            }
            prepared.push({layer,state});
        }
        for(const {layer,state} of prepared)for(const [key,value] of Object.entries(state)) {
            layer.state[key]=copy(value);
            for(const binding of bindings)if(binding.objectID===layer.id&&binding.layerProperty===key)binding.value=copy(value);
        }
    }
    function installModelStates(states,serial,partial=false) {
        if(!states||typeof states!=='object'||Array.isArray(states)||(partial?Object.keys(states).length>models.size:Object.keys(states).length!==models.size)||
           !Number.isSafeInteger(serial)||serial<modelSerial||serial>1e9)throw Error('Invalid native model inventory or generation');
        const prepared=[];let total=0;
        for(const [id,entries] of Object.entries(states)) {
            const model=models.get(id);
            if(!model||!Array.isArray(entries)||entries.length>32)throw Error('Invalid native model layers');
            const keys=new Set(),values=[];total+=entries.length;if(total>2048)throw Error('Model layer budget exceeded');
            for(const value of entries) {
                if(!value||typeof value.key!=='string'||value.key.length>128||keys.has(value.key)||!model.clips.has(value.clip)||
                   typeof value.name!=='string'||value.name.length>4096||typeof value.visible!=='boolean'||typeof value.additive!=='boolean'||typeof value.single!=='boolean')throw Error('Invalid native animation layer');
                const old=model.records.get(value.key);if(old&&old.state.clip!==value.clip)throw Error('Animation identity changed');
                const controls={...value,blendin:value.blendin??false,blendout:value.blendout??false,blendtime:value.blendtime??0.5};
                for(const key of [...Object.keys(modelNumbers),...modelFlags])controls[key]=checkedModelProperty(key,controls[key]);
                const overrides=value.overrides??[];
                if(!Array.isArray(overrides)||new Set(overrides).size!==overrides.length||overrides.some(key=>!Object.hasOwn(modelNumbers,key)&&!modelFlags.includes(key)))throw Error('Invalid model property overrides');
                values.push({...controls,overrides:[...overrides],clock:modelClock(value.clock)});keys.add(value.key);
            }
            prepared.push([model,values]);
        }
        for(const [model,values] of prepared) {
            for(const entry of model.records.values())entry.alive=false;
            model.order=values.map(value=>{
                let record=model.records.get(value.key);
                if(!record){record=modelRecord(model,value);model.records.set(value.key,record);}
                record.alive=true;record.state=value;return record;
            });
        }
        modelSerial=serial;
    }
    function findModelLayer(model,key) {
        if(typeof key==='number')return Number.isInteger(key)&&key>=0?model.order[key]??null:null;
        // The observed reference scan retains the last matching custom name.
        if(typeof key==='string'&&key.length)for(let i=model.order.length-1;i>=0;i--)if(model.order[i].state.name===key)return model.order[i];
        return null;
    }
    function createModelLayer(model,animation,options,single) {
        if(retiringSceneIDs.has(model.id))throw Error('Cannot create animation layers on a retiring model');
        let config={},clip;
        if(typeof animation==='string')clip=[...model.clips.values()].find(value=>value.name===animation);
        else if(animation&&typeof animation==='object'&&!Array.isArray(animation)) {
            config={...animation};const value=config.animation;delete config.animation;
            if(Number.isSafeInteger(value)&&value>=0)clip=model.clips.get(String(value));
        } else throw Error('Animation must be a clip name or configuration object');
        if(options!==undefined){if(!options||typeof options!=='object'||Array.isArray(options))throw Error('Animation options must be an object');config={...config,...options};}
        if(!clip)return null;
        config={blendin:true,blendout:true,...config};
        const allowed=['name','rate','blend','visible','additive','blendin','blendout','blendtime','autosort','index'];
        if(Object.keys(config).some(key=>!allowed.includes(key)))throw Error('Unsupported model animation configuration');
        if(config.name!==undefined&&(typeof config.name!=='string'||config.name.length>4096))throw Error('Invalid animation layer name');
        for(const key of ['visible','additive','blendin','blendout','autosort'])if(config[key]!==undefined&&typeof config[key]!=='boolean')throw Error('Invalid animation boolean option: '+key);
        const rate=modelFloat(config.rate??1,-100,100,'rate'),blend=modelFloat(config.blend??1,0,1,'blend');
        if(config.blendtime!==undefined)modelFloat(config.blendtime,0,3600,'blend time');
        let insertion=model.order.length;
        if(config.index!==undefined){
            if(!Number.isInteger(config.index)||config.index < -2147483648||config.index > 2147483647)throw Error('Invalid animation insertion index');
            insertion=config.index>=0&&config.index<model.order.length?config.index:Math.max(0,model.order.length-1);
        }
        if(config.autosort===true){insertion=0;for(let i=model.order.length-1;i>=0;i--)if(!model.order[i].state.additive){insertion=i+1;break;}}
        if(model.order.length>=32||[...models.values()].reduce((n,value)=>n+value.order.length,0)>=2048||modelSerial>=1e9)throw Error('Model animation layer budget exceeded');
        const key='script:'+(modelSerial+1);
        modelCommand(model.id,key,'create',{clip:clip.id,config,single});modelSerial++;
        const state={key,clip:clip.id,name:config.name??'',rate,blend,visible:config.visible??true,additive:config.additive??false,single,
            blendin:config.blendin,blendout:config.blendout,blendtime:config.blendtime??0.5,overrides:[],
            clock:{time:Math.fround(clip.initialFrame*clip.frameDuration),rate,paused:false,completed:false,reversed:false}};
        const record=modelRecord(model,state);model.records.set(key,record);model.order.splice(insertion,0,record);return record.view;
    }
    function modelMethod(id,name) {
        return (...args)=>{
            const model=models.get(id);if(!model)throw Error('This model has no supported animation runtime');
            if(name==='getAnimationLayerCount')return model.order.length;
            if(name==='getAnimationLayer')return findModelLayer(model,args[0])?.view??null;
            if(name==='createAnimationLayer'||name==='playSingleAnimation')return createModelLayer(model,args[0],args[1],name==='playSingleAnimation');
            const key=args[0];let found;
            if(typeof key==='string')found=model.order.filter(record=>record.state.name===key&&key.length);
            else if(typeof key==='number'){const record=findModelLayer(model,key);found=record?[record]:[];}
            else {const record=modelViews.get(key);found=record?.model===model&&record.alive?[record]:[];}
            for(const record of found){modelCommand(id,record.state.key,'destroy');record.alive=false;modelCallbackCount-=record.callbacks.length;record.callbacks=[];model.order.splice(model.order.indexOf(record),1);}
            return found.length>0;
        };
    }
    function prepareModelEvents(events) {
        if(!Array.isArray(events)||events.length>128)throw Error('Invalid model animation event batch');
        return events.map(event=>{
            if(event?.kind==='marker') {
                const model=models.get(event.id),clip=model?.clips.get(event.clip),index=event.eventIndex;
                if(!clip||!Number.isInteger(index)||index<0||index>=clip.events.length)throw Error('Unknown model animation marker');
                // Markers belong to the model, even if a previous callback has
                // removed the originating animation layer while I/O was pending.
                return {objectID:model.id,json:clip.events[index]};
            }
            if(event?.kind!==undefined&&event.kind!=='ended')throw Error('Unknown model event kind');
            const record=models.get(event?.id)?.records.get(event?.key);
            if(!record)throw Error('Unknown model animation event');
            return {record,clock:modelClock(event.clock)};
        });
    }
    function deliverModelEvents(events) {
        for(const event of events) {
            modelEventCounts.received=Math.min(1e9,modelEventCounts.received+1);
            if(event.json!==undefined) {
                modelEventCounts.markers=Math.min(1e9,modelEventCounts.markers+1);
                for(const binding of bindings)if(binding.objectID===event.objectID&&binding.layerProperty&&!binding.disabled&&typeof binding.exports.animationEvent==='function') {
                    modelEventCounts.markerCalls=Math.min(1e9,modelEventCounts.markerCalls+1);
                    invoke(binding,'animationEvent',JSON.parse(event.json),true);
                }
                continue;
            }
            const {record,clock}=event;
            if(!record.alive)record.state.clock=clock;
            const callbacks=record.callbacks.slice();
            for(const listener of callbacks) {
                if(!record.callbacks.includes(listener))continue;
                modelEventCounts.calls=Math.min(1e9,modelEventCounts.calls+1);
                try {withTimelineBinding(listener.binding,()=>listener.callback());}
                catch(error){const index=record.callbacks.indexOf(listener);if(index>=0){record.callbacks.splice(index,1);modelCallbackCount--;}fail('model animation ended callback',error);}
            }
        }
        // Retained script references keep their closed handle; the registry
        // only retains live layers, so repeated temporary clips do not leak.
        for(const model of models.values())for(const [key,record] of model.records)if(!record.alive){modelCallbackCount-=record.callbacks.length;record.callbacks=[];model.records.delete(key);}
    }
"""#
