import Foundation

let sceneScriptCreationLibrary = #"""
    let creationAvailable=false;
    function createSceneLayer(configuration) {
        if(timelineModuleLoading)throw Error('createLayer is unavailable in module global scope');
        if(!creationAvailable)throw Error('This renderer does not support dynamic scene creation');
        if(retiringSceneIDs.size)throw Error('Creation during destroy callbacks is not supported yet');
        if(configuration===null||!['string','object'].includes(typeof configuration)||Array.isArray(configuration))throw Error('Expected a layer configuration or asset handle');
        const request=JSON.stringify({method:'createLayer',arguments:{configuration},scope:'callback',bindingKey:timelineBinding?.key});
        let bytes=0;
        for(const value of request){const code=value.codePointAt(0);bytes+=code<128?1:code<2048?2:code<65536?3:4;}
        if(bytes>512*1024)throw Error('Layer creation request exceeds 512 KiB');
        const reply=JSON.parse(nativeHostRequest(request));
        if(reply.ok!==true)throw Error(reply.error||'Native scene creation failed');
        const {id,inventory:message}=reply.value||{};
        if(typeof id!=='string'||!message||message.inventoryRevision!==inventoryRevision+1||
           !Array.isArray(message.layers)||message.layers.length!==layers.length+1||message.layers.length>5000||
           !Array.isArray(message.bindings)||message.bindings.length>128||
           !Array.isArray(message.retainedBindings)||!Array.isArray(message.retainedLayerIDs))throw Error('Invalid native creation inventory');
        const existing=new Set(layers.map(layer=>layer.id)), retained=new Set(message.retainedLayerIDs);
        const ids=new Set(message.layers.map(layer=>layer.id));
        if(existing.has(id)||retained.size!==existing.size||[...existing].some(key=>!retained.has(key))||
           ids.size!==message.layers.length||!ids.has(id)||[...existing].some(key=>!ids.has(key)))throw Error('Invalid created layer identity');
        const definition=message.layers.find(layer=>layer.id===id);
        const oldBindings=new Set(message.retainedBindings);
        const additions=message.bindings.filter(binding=>!oldBindings.has(binding.key));
        if(additions.some(binding=>binding.objectID!==id))throw Error('Creation changed an existing script owner');
        layerWriteCapabilities=message.layerWriteCapabilities||null;
        const newTimelines=message.timelines.filter(item=>!timelineAnimations.has(item.path));
        const paths=new Set(newTimelines.map(item=>item.path));
        loadTimelineAnimations(newTimelines);
        installTimelineStates(Object.fromEntries(Object.entries(message.timelineStates).filter(([key])=>paths.has(key))),true);
        const newModels=Object.fromEntries(Object.entries(message.models||{}).filter(([key])=>!models.has(key)));
        loadModels(newModels);
        installModelStates(Object.fromEntries(Object.entries(message.modelStates||{}).filter(([key])=>Object.hasOwn(newModels,key))),modelSerial,true);
        const layer=layerRecord(definition);
        layers.push(layer);sceneLayerOrder.push(layer);sceneLayerHandles.set(layer.view,layer);
        installModelTransforms(Object.fromEntries(Object.entries(message.modelTransforms||{}).filter(([key])=>Object.hasOwn(newModels,key))));
        // Publish metadata before init: a child init may create another child.
        // Keep existing command arrays, bindings and current callback ownership.
        inventoryDefinition={...inventoryDefinition,...message};
        inventoryRevision=message.inventoryRevision;
        loadBindings(additions);
        const addedBindings=bindings.filter(binding=>binding.objectID===id);
        for(const binding of addedBindings)invoke(binding,'init',copy(binding.value),true);
        for(const binding of addedBindings) {
            updateScriptProperties(binding);
            invoke(binding,'applyUserProperties',{...engine.userProperties});
        }
        if(mediaSnapshot)deliverMedia(mediaSnapshot,addedBindings,true);
        return layer.view;
    }
"""#
