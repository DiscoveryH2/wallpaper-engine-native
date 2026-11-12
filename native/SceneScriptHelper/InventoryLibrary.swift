import Foundation

/// Internal host-driven reconciliation. The author-facing lifecycle adapter
/// will use the same resource inventory once synchronous preparation is wired.
let sceneScriptInventoryLibrary = #"""
    let inventoryRevision=0;
    const retiringSceneIDs=new Set();
    let inventoryDefinition=null, destructionAvailable=false, destructionOverflow=false;
    const pendingSceneDestruction=new Set();
    function destroySceneLayer(key) {
        if(timelineModuleLoading)throw Error('destroyLayer is unavailable in module global scope');
        if(!destructionAvailable)throw Error('This renderer does not support dynamic scene destruction');
        const layer=findSceneLayer(key);
        if(!layer)return false;
        if(!pendingSceneDestruction.has(layer.id)&&pendingSceneDestruction.size>=256) {
            destructionOverflow=true;throw Error('Scene destruction batch exceeds 256 layers');
        }
        pendingSceneDestruction.add(layer.id);return true;
    }
    function flushSceneDestruction() {
        if(destructionOverflow)throw Error('Scene destruction batch overflow; response not committed');
        // Copy and clear before callbacks: a destroy callback's new request is
        // processed by the next host request, never recursively in this pass.
        const retired=new Set([...pendingSceneDestruction].filter(id=>layers.some(layer=>layer.id===id)));
        pendingSceneDestruction.clear();
        if(!retired.size)return [];
        const previous=inventoryDefinition;
        const definitions=new Map(previous.layers.map(layer=>[layer.id,layer]));
        const kept=sceneLayerOrder.filter(layer=>!retired.has(layer.id));
        const paths=layers.filter(layer=>retired.has(layer.id)).map(layer=>layer.path+'/');
        const keepPath=path=>!paths.some(prefix=>path.startsWith(prefix));
        const message={...previous,inventoryProtocol:1,inventoryRevision:inventoryRevision+1,runtime:engine.runtime,
            layers:kept.map(layer=>{const data={...definitions.get(layer.id)};if(retired.has(data.parentID))delete data.parentID;return data;}),
            bindings:previous.bindings.filter(binding=>keepPath(binding.key)),
            timelines:previous.timelines.filter(item=>keepPath(item.path)),
            models:Object.fromEntries(Object.entries(previous.models||{}).filter(([id])=>!retired.has(id))),
            retainedLayerIDs:kept.map(layer=>layer.id),
            retainedBindings:previous.bindings.filter(binding=>keepPath(binding.key)).map(binding=>binding.key),
            timelineStates:{},modelStates:{},modelEvents:[],modelTransforms:{},modelSerial};
        reconcileInventory(message,true);
        if(destructionOverflow)throw Error('Scene destruction callback overflow; response not committed');
        return [...retired];
    }
    function inventoryStatistics() {
        return {layers:layers.length,bindings:bindings.length,timers:timers.size,
            audioBuffers:audioRegistrations.length,timelines:timelineAnimations.size,
            effects:effectRecords.size,materials:materialRecords.size,
            materialProperties:materialProperties.size,videos:videos.size,models:models.size};
    }
    function reconcileInventory(message,authorRetirement=false) {
        if(!initialized||message.inventoryProtocol!==1||message.inventoryRevision!==inventoryRevision+1||
           !Array.isArray(message.layers)||message.layers.length>5000||
           !Array.isArray(message.bindings)||message.bindings.length>128||
           !Array.isArray(message.retainedLayerIDs)||!Array.isArray(message.retainedBindings)||
           !Number.isFinite(message.runtime)||message.runtime!==engine.runtime)throw Error('Invalid scene inventory transaction');
        lifecycleAvailable=true;
        const ids=new Set(message.layers.map(layer=>layer.id)),retained=new Set(message.retainedLayerIDs);
        const oldIDs=new Set(layers.map(layer=>layer.id)),bindingKeys=new Set(message.bindings.map(binding=>binding.key));
        const retainedBindings=new Set(message.retainedBindings);
        if(ids.size!==message.layers.length||retained.size!==message.retainedLayerIDs.length||
           bindingKeys.size!==message.bindings.length||retainedBindings.size!==message.retainedBindings.length||
           [...retained].some(id=>!ids.has(id)||!oldIDs.has(id))||
           [...oldIDs].some(id=>ids.has(id)&&!retained.has(id))||
           [...retainedBindings].some(key=>!bindingKeys.has(key)))throw Error('Invalid retained scene identity');
        const retired=layers.filter(layer=>!retained.has(layer.id));
        const retiredPaths=retired.map(layer=>layer.path+'/');
        const retiredOwner=binding=>binding&&binding.objectID!==''&&!retained.has(binding.objectID);
        const retiredPath=path=>retiredPaths.some(prefix=>path.startsWith(prefix));
        const newTimelinePaths=new Set((message.timelines||[]).filter(item=>!timelineAnimations.has(item.path)||retiredPath(item.path)).map(item=>item.path));
        const newModelIDs=new Set(Object.keys(message.models||{}).filter(id=>!models.has(id)));
        // Refresh surviving native state before destroy callbacks. A callback's
        // cross-object commands must not be overwritten by the incoming snapshot.
        if(!authorRetirement) {
        installTimelineStates(Object.fromEntries([...timelineAnimations].map(([path,entry])=>
            [path,retiredPath(path)?entry.snapshot():message.timelineStates[path]])));
        installModelStates(Object.fromEntries([...models].map(([id,model])=>
            [id,retained.has(id)?message.modelStates[id]:model.order.map(record=>record.state)])),message.modelSerial);
        installModelTransforms(Object.fromEntries(Object.entries(message.modelTransforms??{}).filter(([id])=>retained.has(id))));
        }
        for(const layer of retired)retiringSceneIDs.add(layer.id);
        // Owner callbacks still have access to the retiring object. Registry
        // removal and service cleanup happen after the complete callback pass.
        for(const binding of bindings.slice())if(retiredOwner(binding))invoke(binding,'destroy',undefined);
        // Remove old-slot commands before registering a replacement at that
        // address; membership after slot reuse alone cannot identify the owner.
        const survivingCommands=timelineCommands.filter(command=>authorRetirement||!retiredPath(command.path));
        timelineCommands.length=0;
        for(const command of survivingCommands){command.ordinal=timelineCommands.length;timelineCommands.push(command);}
        for(let i=bindings.length-1;i>=0;i--)if(!retainedBindings.has(bindings[i].key))bindings.splice(i,1);
        for(const timer of timers)if(retiredOwner(timer.binding))timers.delete(timer);
        for(let i=audioRegistrations.length-1;i>=0;i--)if(retiredOwner(audioRegistrations[i].binding))audioRegistrations.splice(i,1);
        for(const [path,effect] of effectRecords)if(retiredPath(path)) {effect.alive=false;effectRecords.delete(path);}
        for(const [path,material] of materialRecords)if(retiredPath(path)) {
            material.alive=false;
            for(const property of material.properties.values())materialProperties.delete(property.path);
            materialRecords.delete(path);
        }
        for(const [path,entry] of timelineAnimations)if(retiredPath(path)) {entry.retire();timelineAnimations.delete(path);}
        for(const [id,model] of models) {
            for(const record of model.records.values()) {
                const previous=record.callbacks.length;
                record.callbacks=record.callbacks.filter(listener=>retained.has(id)&&!retiredOwner(listener.binding));
                modelCallbackCount-=previous-record.callbacks.length;
                if(!retained.has(id))record.alive=false;
            }
            if(!retained.has(id))models.delete(id);
        }
        const videoKeys=new Set(message.layers.map(layer=>layer.videoTexture?.key).filter(key=>key!==undefined));
        for(const [key,video] of videos) {
            video.removeCallbacks(retiredOwner);
            if(!videoKeys.has(key)) {video.retire();videos.delete(key);}
        }
        for(const layer of retired) {layer.alive=false;layer.animation?.retire();}
        const previousLayers=new Map(layers.filter(layer=>retained.has(layer.id)).map(layer=>[layer.id,layer]));
        layers=layers.filter(layer=>retained.has(layer.id));
        layerWriteCapabilities=message.layerWriteCapabilities || null;
        loadTimelineAnimations((message.timelines||[]).filter(item=>!timelineAnimations.has(item.path)));
        installTimelineStates(Object.fromEntries(Object.entries(message.timelineStates).filter(([path])=>newTimelinePaths.has(path))),true);
        loadModels(Object.fromEntries(Object.entries(message.models||{}).filter(([id])=>!models.has(id))));
        installModelStates(Object.fromEntries(Object.entries(message.modelStates).filter(([id])=>newModelIDs.has(id))),modelSerial,true);
        layers=message.layers.map(data=>{
            const old=previousLayers.get(data.id);
            if(old) {old.parentID=data.parentID;return old;}
            return layerRecord(data);
        });
        installSceneLayers();
        installModelTransforms(Object.fromEntries(Object.entries(message.modelTransforms??{}).filter(([id])=>newModelIDs.has(id))));
        const oldBindings=new Set(bindings);
        loadBindings(message.bindings.filter(binding=>!retainedBindings.has(binding.key)));
        if(!authorRetirement)updateTimelineInputs(message.timelineValues);
        const addedBindings=bindings.filter(binding=>!oldBindings.has(binding));
        for(const binding of addedBindings)invoke(binding,'init',copy(binding.value),true);
        for(const binding of addedBindings) {
            updateScriptProperties(binding);
            invoke(binding,'applyUserProperties',{...engine.userProperties});
        }
        if(mediaSnapshot)deliverMedia(mediaSnapshot,addedBindings,true);
        deliverModelEvents(prepareModelEvents(message.modelEvents));
        // Writes to objects destroyed in this transaction cannot escape into a
        // replacement slot. Cross-object writes from destroy remain ordered.
        function prune(commands,keep) {
            const accepted=commands.filter(keep);commands.length=0;
            for(const command of accepted){if(Object.hasOwn(command,'ordinal'))command.ordinal=commands.length;commands.push(command);}
        }
        // Author deletion is committed against the still-live native stores.
        // Keep earlier commands (including dynamic model serial allocations)
        // until the host validates the complete batch, then retire resources.
        if(!authorRetirement) {
            prune(timelineCommands,command=>timelineAnimations.has(command.path));
            prune(modelCommands,command=>models.has(command.id));
        }
        prune(soundCommands,command=>ids.has(command.id));
        retiringSceneIDs.clear();
        inventoryRevision=message.inventoryRevision;
        inventoryDefinition=message;
    }
"""#
