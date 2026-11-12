import Foundation
import JavaScriptCore
import Darwin

if CommandLine.arguments.dropFirst().contains("--evaluate-property-conditions") {
    exit(runNativePropertyConditions())
}

// A standalone process containing no JSExport objects. One bounded JSON
// callback allows synchronous resource requests to the supervising host.
// The parent controls wall-clock time and terminates this exact process on stalls.
let bootstrap = #"""
'use strict';
var __nativeRequest = ((nativeHostRequest) => {
    const bindings = [];
    \#(sceneScriptMaterialLibrary)
    \#(sceneScriptEffectLibrary)
    let initialized = false, lifecycleAvailable=false;
    const shared = Object.create(null);
    \#(sceneScriptStandardLibrary)
    const audioRegistrations = [];
    function registerAudioBuffers(resolution) {
        if(![16,32,64].includes(resolution))throw Error('Audio resolution must be 16, 32 or 64');
        if(audioRegistrations.length>=128)throw Error('Audio buffer registration limit exceeded');
        const value={left:new Float32Array(resolution),right:new Float32Array(resolution),average:new Float32Array(resolution)};
        audioRegistrations.push({resolution,value,binding:timelineBinding});return value;
    }
    function updateAudio(bands) {
        for(const {resolution,value} of audioRegistrations) {
            const channels=bands && bands[String(resolution)];
            for(let i=0;i<resolution;i++) {
                const l=channels?.left?.[i],r=channels?.right?.[i];
                value.left[i]=Number.isFinite(l)?Math.max(0,Math.min(8,l)):0;
                value.right[i]=Number.isFinite(r)?Math.max(0,Math.min(8,r)):0;
                value.average[i]=(value.left[i]+value.right[i])*0.5;
            }
        }
    }
    const engine = {
        runtime:0,frametime:0,screenResolution:new Vec2(1280,720),canvasSize:new Vec2(1280,720),userProperties:Object.create(null),
        get timeOfDay(){ const d=new Date();return (d.getHours()*3600+d.getMinutes()*60+d.getSeconds()+d.getMilliseconds()/1000)/86400; },
        isDesktopDevice:()=>true,isMobileDevice:()=>false,isWallpaper:()=>true,isScreensaver:()=>false,
        isPortrait:()=>engine.screenResolution.y>engine.screenResolution.x,
        isLandscape:()=>engine.screenResolution.x>=engine.screenResolution.y,isRunningInEditor:()=>false,
        AUDIO_RESOLUTION_16:16,AUDIO_RESOLUTION_32:32,AUDIO_RESOLUTION_64:64,registerAudioBuffers
    };
    const inputState = {cursorLeftDown:false,cursorRightDown:false,cursorScreenPosition:new Vec2(),cursorWorldPosition:new Vec3()};
    // A script may transform its local copy of a cursor vector. Such edits
    // must not mutate the native input seen by itself or subsequent bindings.
    const input = Object.freeze({
        get cursorLeftDown(){requirePointerInput();return inputState.cursorLeftDown;},
        get cursorRightDown(){requirePointerInput();return inputState.cursorRightDown;},
        get cursorScreenPosition(){requirePointerInput();return inputState.cursorScreenPosition.copy();},
        get cursorWorldPosition(){requirePointerInput();return inputState.cursorWorldPosition.copy();}
    });
    \#(sceneScriptTextureAnimationLibrary)
    \#(sceneScriptVideoTextureLibrary)
    \#(sceneScriptTimelineAnimationLibrary)
    \#(sceneScriptModelAnimationLibrary)
    \#(sceneScriptCameraLibrary)
    \#(sceneScriptScenePropertyLibrary)
    \#(sceneScriptSceneLayerLibrary)
    const errors = [];
    const soundCommands = [];
    let propertyTypes = {};
    let layerWriteCapabilities = null;
    let pointerInputAvailable = false;
    function requirePointerInput() {
        if(!pointerInputAvailable)throw Error('Pointer input is not available in this rendering backend');
    }
    let layers = [];
    const fail = (key,error) => { if(errors.length<128)errors.push(key+': '+String(error && error.message || error).slice(0,2048)); };
    \#(sceneScriptRuntimeServices)
    \#(sceneScriptMediaLibrary)
    \#(sceneScriptInventoryLibrary)
    \#(sceneScriptAssetLibrary)
    \#(sceneScriptCreationLibrary)
    function initial(value,property) {
        if(['origin','angles','scale','color','size','parallaxDepth','clearcolor','ambientcolor','skylightcolor','bloomtint','backgroundcolor','compositecolor'].includes(property)) {
            const parts=typeof value==='string'?value.trim().split(/[\s,]+/).map(Number):
                Array.isArray(value)?value:value&&typeof value==='object'&&Object.hasOwn(value,'x')?
                ['x','y','z'].filter(key=>Object.hasOwn(value,key)).map(key=>value[key]):[];
            if(parts.length===3 && parts.every(Number.isFinite)) return new Vec3(...parts);
            if(parts.length===2 && parts.every(Number.isFinite)) return new Vec2(...parts);
        }
        return value;
    }
    const copy = value => value instanceof Vector ? value.copy() : value;
    function coerce(value,previous) {
        if(value===undefined) return previous;
        if(previous instanceof Vector) {
            const type=previous.constructor;
            const vector=new type(value);
            if(!Object.values(vector).every(Number.isFinite))throw Error('Non-finite vector return');
            return vector;
        }
        if(typeof previous==='number') {
            if(typeof value!=='number'||!Number.isFinite(value))throw Error('Expected a finite numeric property return');
        } else if(typeof previous==='boolean') {
            if(typeof value!=='boolean')throw Error('Expected a boolean property return');
        } else if(typeof previous==='string') {
            if(typeof value!=='string'||value.length>65536)throw Error('Expected a bounded string property return');
        } else if(value!==null && !['string','number','boolean'].includes(typeof value)) {
            throw Error('Unsupported property return type');
        }
        return value;
    }
    function invoke(binding,name,arg,updatesValue=false) {
        if(binding.disabled || typeof binding.exports[name]!=='function')return;
        if(binding.modelProperty&&!binding.modelProperty.record?.alive)return;
        try {
            const value=withTimelineBinding(binding,()=>name==='animationEvent'?
                binding.exports[name](arg,copy(binding.timelineOverride?binding.value:binding.timelineSample ?? binding.value)):
                binding.exports[name](arg));
            if(updatesValue) {
                if(name==='animationEvent' && value===undefined)return;
                if(binding.sceneProperty && value===undefined)return;
                if(binding.effect && value===undefined)return;
                if(binding.material && value===undefined)return;
                if(binding.modelProperty && value===undefined)return;
                if(isModelTransform(binding.objectID,binding.layerProperty) && value===undefined)return;
                if(binding.timeline && value===undefined)return;
                binding.value=coerce(value,binding.value);
                if(binding.timeline)binding.timelineOverride=true;
                if(binding.sceneProperty)publishSceneProperty(binding.sceneProperty,binding.value);
                if(binding.effect)publishEffectVisibility(binding.effect,binding.value);
                if(binding.material)publishMaterialValue(binding.material,binding.value);
                if(binding.modelProperty)writeModelProperty(binding.modelProperty.record,binding.modelProperty.property,binding.value);
                if(binding.layerProperty) {
                    const layer=layers.find(layer=>layer.id===binding.objectID);
                    if(layer&&Object.hasOwn(layer.state,binding.layerProperty)) {
                        if(binding.timeline) {
                            publishModelTransform(layer,binding.layerProperty,binding.value);
                            layer.state[binding.layerProperty]=copy(binding.value);
                        }
                        else publishLayerValue(layer,binding.layerProperty,binding.value);
                    }
                }
            }
        } catch(error) { binding.disabled=true; fail(binding.key+' '+name,error); }
    }
    function publishLayerValue(layer,key,value) {
        const next=coerce(value,layer.state[key]);
        publishModelTransform(layer,key,next);
        layer.state[key]=copy(next);layer.changes[key]=copy(next);
        for(const binding of bindings)if(binding.objectID===layer.id&&binding.layerProperty===key) {
            binding.value=copy(next);if(binding.timeline)binding.timelineOverride=true;
        }
    }
    function layerRecord(layer) {
        const prepared=Object.create(null);
        Object.assign(prepared,{origin:new Vec3(),angles:new Vec3(),scale:new Vec3(1),color:new Vec3(1),parallaxDepth:new Vec2(1),alpha:1,opacity:1,visible:true});
        for(const [key,value] of Object.entries(layer))if(!['initialConfig','propertyPath','parentID','textureAnimation','videoTexture','sound','effects','model','modelMaterials'].includes(key))prepared[key]=initial(value,key);
        if(layer.modelMaterials!==undefined) {
            if(layer.model!==true||!Array.isArray(layer.modelMaterials))throw Error('Invalid model material metadata');
            layer.modelMaterials.forEach(materialRecord);
        }
        const record={alive:true,path:layer.propertyPath,id:String(layer.id),name:layer.name,parentID:layer.parentID,initialConfig:JSON.stringify(layer.initialConfig??{}),state:prepared,changes:Object.create(null),animation:textureAnimation(layer.textureAnimation),sound:layer.sound?{...layer.sound}:null,
            video:videoTexture(layer.videoTexture),effects:(layer.effects||[]).map(effectRecord)};
        record.view=new Proxy(prepared,{
            get:(target,key)=>{
                if(layer.model===true&&modelMethods.includes(key))return modelMethod(record.id,key);
                if(key==='getParent')return ()=>layers.find(candidate=>candidate.id===record.parentID)?.view;
                if(key==='getChildren')return ()=>layers.filter(candidate=>candidate.parentID===record.id).map(candidate=>candidate.view);
                if(key==='getTextureAnimation')return ()=>record.animation?.view ?? null;
                if(key==='getVideoTexture')return ()=>record.video?.view ?? null;
                if(key==='getEffectCount')return ()=>record.effects.length;
                if(key==='getEffect')return key=>findEffect(record.effects,key);
                if(key==='getAnimation')return name=>ownerTimeline(name,record.id);
                if(record.sound && ['isPlaying','play','pause','stop'].includes(key))return ()=>{
                    if(!record.sound.available)throw Error('Sound layer is not supported by this host');
                    if(key==='isPlaying')return !!record.sound.playing;
                    if(soundCommands.length>=128)throw Error('Sound command limit exceeded');
                    soundCommands.push({id:record.id,action:key});
                    // Commands are ordered. The next native frame replaces
                    // this immediate intent with the actual player state.
                    record.sound.playing=key==='play';
                };
                if(key==='getTransformMatrix')return ()=>({m:layerWorldMatrix(record)});
                if(key in target)return copy(target[key]);
                throw Error('Unsupported thisLayer property: '+String(key));
            },
            set:(target,key,value)=>{
                if(!Object.hasOwn(target,key)||['id','name'].includes(key))throw Error('Unsupported thisLayer write: '+String(key));
                if(layerWriteCapabilities && !layerWriteCapabilities[record.id]?.includes(key))throw Error('Layer write is not available in this rendering backend: '+String(key));
                publishLayerValue(record,key,value);return true;
            }
        });
        const properties=record.view;
        record.view=new Proxy(properties,{
            get:(target,key)=>{
                if(!record.alive)throw Error('Scene layer has been removed');
                const value=Reflect.get(target,key);
                return typeof value==='function'?(...args)=>{
                    if(!record.alive)throw Error('Scene layer has been removed');
                    return value(...args);
                }:value;
            },
            set:(target,key,value)=>{
                if(!record.alive)throw Error('Scene layer has been removed');
                return Reflect.set(target,key,value);
            }
        });
        return record;
    }
    const scene=makeSceneView({getLayer:getSceneLayer,getLayerCount:()=>sceneLayerOrder.length,
        enumerateLayers:()=>sceneLayerOrder.map(layer=>layer.view),sortLayer:sortSceneLayer,destroyLayer:destroySceneLayer,createLayer:createSceneLayer,
        getLayerIndex:getSceneLayerIndex,getInitialLayerConfig,
        getCameraTransforms,setCameraTransforms,getAnimation:sceneTimeline});
    const console={log:()=>{},warn:()=>{},error:()=>{}};
    function resolvedProperty(raw) {
        if(!raw || typeof raw!=='object' || !Object.hasOwn(raw,'value'))return raw;
        const user=raw.user;
        if(typeof user==='string' && Object.hasOwn(engine.userProperties,user))return engine.userProperties[user];
        if(user && typeof user==='object' && Object.hasOwn(engine.userProperties,user.name)) {
            if(Object.hasOwn(user,'condition'))return String(engine.userProperties[user.name])===String(user.condition);
            return engine.userProperties[user.name];
        }
        return raw.value;
    }
    function updateScriptProperties(binding) {
        for(const table of binding.propertyTables)for(const [name,definition] of Object.entries(table.definitions)) {
            const raw=Object.hasOwn(binding.scriptProperties,name)?binding.scriptProperties[name]:definition.value;
            let value=resolvedProperty(raw);
            if(definition.kind==='Color')value=new Vec3(value);
            table.values[name]=value;
        }
    }
    function propertyBuilder(binding) {
        const table={definitions:Object.create(null),values:Object.create(null)},builder=Object.create(null);
        for(const kind of ['Checkbox','Slider','Text','Combo','Color'])builder['add'+kind]=definition=>{
            if(!definition || typeof definition.name!=='string' || definition.name.length>256 || Object.keys(table.definitions).length>=256)throw Error('Invalid script property definition');
            table.definitions[definition.name]={...definition,kind};return builder;
        };
        builder.finish=()=>{binding.propertyTables.push(table);updateScriptProperties(binding);return table.values;};
        return builder;
    }
    function applyProperties(changes,notify,targets=bindings.slice()) {
        const converted=Object.create(null);
        for(const [key,value] of Object.entries(changes))converted[key]=propertyTypes[key]==='color'?new Vec3(value):value;
        Object.assign(engine.userProperties,converted);
        updateSceneProperties();
        updateEffectProperties();
        updateMaterialProperties();
        for(const binding of targets) {
            updateScriptProperties(binding);
            if(notify)invoke(binding,'applyUserProperties',converted);
        }
    }
    function loadBindings(definitions) {
        for(const data of definitions) {
            if(data.prepareError){fail(data.key,data.prepareError);continue;}
            try {
                const exports=JSON.stringify(data.exports);
                const suffix='\n;return Object.fromEntries('+exports+'.map(name=>[name,eval(name)]));';
                const imports=(data.imports || []).map(item=>{
                    const module=builtinModules[item.module];
                    if(!module || (item.member!=='*'&&!Object.hasOwn(module,item.member)))throw Error('Unknown built-in import '+item.module+'.'+item.member);
                    return item.member==='*'?module:module[item.member];
                });
                const declarations=(data.imports || []).map((item,i)=>'const '+item.local+'=__nativeImports['+i+'];').join('\n');
                const layerProperty=/^\/objects\/\d+\/[^/]+$/.test(data.key)?data.property:null;
                const material=materialProperties.get(data.key);
                const binding={key:data.key,objectID:data.objectID,layerProperty,effect:effectRecords.get(data.key),material,value:material?materialValue(material.value):initial(data.value,data.property),timeline:timelineAnimations.has(data.key),timelineOverride:false,exports:{},disabled:false,propertyTables:[],scriptProperties:data.scriptProperties || {}};
                binding.sceneProperty=/^\/general\/[^/]+$/.test(data.key)&&scenePropertyRecords.has(data.property)?data.property:null;
                if(binding.sceneProperty)binding.value=copy(scenePropertyRecords.get(binding.sceneProperty).value);
                binding.modelProperty=modelPropertyAt(data.key,data.objectID);
                if(binding.modelProperty?.record)binding.value=binding.modelProperty.record.state[binding.modelProperty.property];
                const make=new Function('shared','engine','input','Vec2','Vec3','Vec4','thisLayer','thisScene','console','createScriptProperties','__nativeImports','localStorage','MediaPlaybackEvent','thisObject',"'use strict';\n"+declarations+'\n'+data.source+suffix);
                const owner=layers.find(layer=>layer.id===data.objectID)?.view ?? null;
                timelineModuleLoading=true;
                try {
                    binding.exports=withTimelineBinding(binding,()=>make(shared,engine,input,Vec2,Vec3,Vec4,owner,scene,console,()=>propertyBuilder(binding),imports,localStorage,MediaPlaybackEvent,propertyObject(binding,owner)));
                } finally { timelineModuleLoading=false; }
                bindings.push(binding);
                if(binding.sceneProperty)binding.value=copy(scenePropertyRecords.get(binding.sceneProperty).value);
                // The model may already have accumulated motion when a new
                // script context is created. init(value) and thisLayer must
                // observe the same current property, including module writes.
                if(isModelTransform(binding.objectID,binding.layerProperty)) {
                    const layer=layers.find(layer=>layer.id===binding.objectID);
                    if(layer)binding.value=copy(layer.state[binding.layerProperty]);
                }
                const supported=['init',...(lifecycleAvailable?['destroy']:[]),'update','applyUserProperties','animationEvent','cursorDown','cursorUp','cursorClick','cursorMove','cursorEnter','cursorLeave',...mediaEventNames];
                for(const name of data.exports)if(!supported.includes(name))fail(data.key,'Event not delivered by this host: '+name);
            } catch(error) { fail(data.key,error); }
        }
    }
    function load(message) {
        if(initialized)throw Error('A script session can only be initialized once');
        initialized = true;
        lifecycleAvailable=message.inventoryAvailable===true;
        destructionAvailable=message.destructionAvailable===true;
        creationAvailable=message.creationAvailable===true;
        inventoryDefinition=message;
        loadStorage(message);
        propertyTypes=message.propertyTypes || {};
        layerWriteCapabilities=message.layerWriteCapabilities || null;
        pointerInputAvailable=message.pointerInputAvailable===true;
        engine.canvasSize=new Vec2(message.canvas || {x:1280,y:720});
        engine.screenResolution=new Vec2(message.screen || engine.canvasSize);
        applyProperties(message.properties,false);
        loadTimelineAnimations(message.timelines || []);
        loadSceneProperties(message.sceneProperties);
        for(const [path,value] of Object.entries(message.timelineValues || {}))updateSceneTimeline(path,value);
        installTimelineStates(message.timelineStates);
        loadModels(message.models || {});
        installModelStates(message.modelStates,message.modelSerial);
        layers=message.layers.map(layerRecord);
        installSceneLayers();
        installModelTransforms(message.modelTransforms??{});
        loadBindings(message.bindings);
        updateTimelineInputs(message.timelineValues);
        const initialBindings=bindings.slice();
        for(const binding of initialBindings)invoke(binding,'init',copy(binding.value),true);
        applyProperties(message.properties,true,initialBindings);
        deliverMedia(message.media);
        deliverModelEvents(prepareModelEvents(message.modelEvents));
    }
    function setInput(value) {
        inputState.cursorLeftDown=!!value.cursorLeftDown;inputState.cursorRightDown=!!value.cursorRightDown;
        inputState.cursorScreenPosition=new Vec2(value.cursorScreenPosition);
        inputState.cursorWorldPosition=new Vec3(value.cursorWorldPosition);
    }
    function frame(message) {
        // Validate the entire native batch before invoking any author callback.
        const animationEvents=prepareAnimationEvents(message.animationEvents ?? []);
        engine.runtime=message.runtime;engine.frametime=message.frametime;
        installModelStates(message.modelStates,message.modelSerial);
        installModelTransforms(message.modelTransforms??{});
        const modelEvents=prepareModelEvents(message.modelEvents);
        advanceVideos();
        installTimelineStates(message.timelineStates);
        updateTimelineInputs(message.timelineValues);
        for(const layer of layers)if(layer.sound) {
            const state=message.sounds?.[layer.id];
            if(state) {
                layer.sound.playing=!!state.playing;
                if(Number.isFinite(state.volume)&&!Object.hasOwn(layer.changes,'volume'))layer.state.volume=state.volume;
            }
        }
        updateTimers();
        updateAudio(message.audio);
        engine.screenResolution=new Vec2(message.screen);
        setInput(message.input);
        deliverMedia(message.media);
        deliverAnimationEvents(animationEvents);
        deliverModelEvents(modelEvents);
        // Deliberate host order: deliver queued events, then update bindings.
        for(const event of message.events) {
            if(!['cursorDown','cursorUp','cursorClick','cursorMove','cursorEnter','cursorLeave'].includes(event.name))continue;
            if(event.input)setInput(event.input);
            const payload={...event.event};
            if(payload.worldPosition)payload.worldPosition=new Vec3(payload.worldPosition);
            if(payload.screenPosition)payload.screenPosition=new Vec2(payload.screenPosition);
            for(const binding of bindings.slice())if(event.objectIDs.includes(binding.objectID))invoke(binding,event.name,payload);
        }
        setInput(message.input);
        for(const binding of bindings.slice())invoke(binding,'update',copy(binding.timelineSample ?? binding.value),true);
    }
    let lastTimelineRequestID=0;
    return text => {
        try {
            const message=JSON.parse(text);
            if(message.sceneLayerProtocol!==1||message.scenePropertyProtocol!==1||message.timelineProtocol!==2||!Number.isSafeInteger(message.requestID)||
               message.requestID<=lastTimelineRequestID||timelineCommands.length!==0||modelCommands.length!==0||message.modelProtocol!==1)throw Error('Invalid timeline/model request protocol or sequence');
            lastTimelineRequestID=message.requestID;
            installCamera(message);
            if(message.op==='load')load(message);
            else if(message.op==='frame')frame(message);
            else if(message.op==='inventory')reconcileInventory(message);
            else if(message.op==='properties') {
                installTimelineStates(message.timelineStates);
                installModelStates(message.modelStates,message.modelSerial);
                installModelTransforms(message.modelTransforms??{});
                deliverModelEvents(prepareModelEvents(message.modelEvents));
                applyProperties(message.properties,true);
            }
            else throw Error('Unsupported script request');
            // Host-driven inventory replacement already performs its callback
            // pass. Requests queued there are deferred to the next request.
            const sceneRetirements=message.op==='inventory'?[]:flushSceneDestruction();
            // Binding-level exceptions are otherwise isolated. Budget failure
            // invalidates this response so no truncated command prefix commits.
            if(timelineCommandOverflow)throw Error('Timeline command batch overflow; response not committed');
            if(modelCommandOverflow)throw Error('Model command batch overflow; response not committed');
            const values=Object.create(null);
            for(const binding of bindings)if(!binding.sceneProperty&&!binding.effect&&!binding.material&&(!binding.timeline||binding.timelineOverride))values[binding.key]=binding.value;
            const layerValues=Object.fromEntries(layers.filter(layer=>Object.keys(layer.changes).length).map(layer=>[layer.id,layer.changes]));
            const textureAnimations=Object.fromEntries(layers.filter(layer=>layer.animation).map(layer=>[layer.id,layer.animation.snapshot()]));
            const result=JSON.stringify({ok:true,values,layers:layerValues,effects:effectSnapshot(),materials:materialSnapshot(),textureAnimations,videoTextures:videoSnapshot(),
                camera:cameraReceipt(),scenePropertyProtocol:1,sceneValues:scenePropertySnapshot(),
                sceneLayerProtocol:1,sceneLayerOrder:sceneLayerOrder.map(layer=>layer.id),
                inventoryProtocol:1,inventoryRevision,sceneRetirements,inventoryStatistics:inventoryStatistics(),
                timelineProtocol:2,requestID:message.requestID,timelineCommands:timelineCommands.splice(0),animationEventCounts,
                modelProtocol:1,modelCommands:modelCommands.splice(0),modelEventCounts,
                soundCommands:soundCommands.splice(0),storage:storageDirty?storageData:undefined,loadedBindings:bindings.length,disabledBindings:bindings.filter(b=>b.disabled).length,audioRegistrations:audioRegistrations.length,timeOfDay:engine.timeOfDay,mediaRevision:mediaSnapshot?.revision,mediaDeliveryCounts,errors:errors.splice(0)});
            storageDirty=false;return result;
        } catch(error) { fail('SceneScript',error);return JSON.stringify({ok:false,values:{},errors:errors.splice(0)}); }
    };
})(__nativeHostRequest);
"""#

func response(_ value: [String: Any]) {
    if var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        data.append(10); try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

guard let context = JSContext() else { exit(1) }
let nativeTransport = NativeScriptHostTransport()
let nativeCall: @convention(block) (String) -> String = { nativeTransport.call($0) }
context.setObject(nativeCall, forKeyedSubscript: "__nativeHostRequest" as NSString)
context.evaluateScript(bootstrap)
// Author modules receive only engine.registerAsset. They cannot reach the raw
// transport through the global object or export a native object into the VM.
context.globalObject.deleteProperty("__nativeHostRequest")
guard context.exception == nil, let entry = context.objectForKeyedSubscript("__nativeRequest") else {
    response(["ok":false,"errors":["Could not initialize the system JavaScriptCore adapter"]]); exit(1)
}
while true {
    do {
        guard let request = try nativeTransport.input.readLine() else { break }
        do {
            guard var message = try JSONSerialization.jsonObject(with: request) as? [String: Any] else { throw ScriptFailure.invalid("Expected a JSON request object") }
            if ["load", "inventory"].contains(message["op"] as? String ?? "") {
                guard let bindings = message["bindings"] as? [[String: Any]], bindings.count <= 128,
                      let layers = message["layers"] as? [[String: Any]], layers.count <= 5000 else { throw ScriptFailure.invalid("Invalid script binding inventory") }
                var processed: [[String: Any]] = []
                var sourceBytes = 0
                for var binding in bindings {
                    guard let source = binding["source"] as? String, source.utf8.count <= 256 * 1024,
                          let key = binding["key"] as? String, key.count <= 4096,
                          binding["objectID"] is String, binding["property"] is String else { throw ScriptFailure.invalid("Invalid script binding") }
                    sourceBytes += source.utf8.count
                    guard sourceBytes <= 2 * 1024 * 1024 else { throw ScriptFailure.invalid("Script sources exceed 2 MiB") }
                    do {
                        let (lowered, exports, imports) = try lowerModule(source)
                        binding["source"] = lowered; binding["exports"] = exports; binding["imports"] = imports
                    } catch {
                        // A syntax/API incompatibility belongs to this binding.
                        // Keep other author scripts and their diagnostics alive.
                        binding["prepareError"] = error.localizedDescription
                        binding.removeValue(forKey: "source")
                    }
                    processed.append(binding)
                }
                message["bindings"] = processed
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            context.exception = nil
            nativeTransport.requestID = message["requestID"] as? Int ?? 0
            nativeTransport.ordinal = 0; nativeTransport.active = true
            let result = entry.call(withArguments: [text])
            nativeTransport.active = false
            guard !nativeTransport.failed, let result, context.exception == nil,
                  let output = result.toString(), output.utf8.count <= 1024 * 1024 else {
                throw ScriptFailure.invalid("JavaScriptCore failed or its response exceeded 1 MiB")
            }
            var data = Data(output.utf8); data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch { response(["ok":false,"errors":[error.localizedDescription]]) }
        if nativeTransport.failed { exit(1) }
    } catch { response(["ok":false,"errors":[error.localizedDescription]]); exit(1) }
}
