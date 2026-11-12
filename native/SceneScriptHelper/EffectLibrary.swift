import Foundation

/// Image-effect visibility is a separate address space from layer properties
/// and material uniforms. No native object is exported into JavaScriptCore.
let sceneScriptEffectLibrary = #"""
    const effectRecords = new Map();
    function publishEffectVisibility(effect,value) {
        if(!effect.alive)throw Error('Effect owner has been removed');
        if(!effect.available)throw Error('Effect is not available in this rendering backend: '+effect.path);
        if(typeof value!=='boolean')throw Error('Effect visibility must be boolean');
        effect.visible=value;effect.overridden=true;
        for(const binding of bindings)if(binding.key===effect.path)binding.value=value;
    }
    function effectRecord(data) {
        if(!data||typeof data.path!=='string'||typeof data.name!=='string'||
           typeof data.visible!=='boolean'||typeof data.available!=='boolean'||
           effectRecords.has(data.path)||effectRecords.size>=4096)throw Error('Invalid effect metadata');
        const effect={alive:true,path:data.path,name:data.name,visible:data.visible,available:data.available,
            property:data.property,overridden:false,materials:Array.isArray(data.materials)?data.materials.map(materialRecord):null};
        effect.view=new Proxy(Object.create(null),{
            get:(_,key)=>{
                if(!effect.alive)throw Error('Effect owner has been removed');
                if(key==='visible')return effect.visible;
                if(key==='name')return effect.name;
                if(key==='getAnimation')return name=>{
                    if(!effect.alive)throw Error('Effect owner has been removed');
                    return ownerTimeline(name,undefined,effect.path.split('/').slice(1,-1).join('/'));
                };
                if(key==='getMaterial')return index=>findMaterial(effect.materials,index);
                if(key==='getMaterialCount')return ()=>{
                    if(!effect.materials)throw Error('Material objects are not available in this rendering backend');
                    return effect.materials.length;
                };
                if(key==='setMaterialProperty')return (name,value)=>setMaterialProperty(effect.materials,name,value);
                throw Error('Unsupported effect property: '+String(key));
            },
            set:(_,key,value)=>{
                if(key!=='visible')throw Error('Unsupported effect write: '+String(key));
                publishEffectVisibility(effect,value);return true;
            }
        });
        effectRecords.set(effect.path,effect);return effect;
    }
    function findEffect(effects,key) {
        if(typeof key==='number') {
            if(!Number.isInteger(key)||key<0)throw Error('Effect index must be a non-negative integer');
            return effects[key]?.view ?? null;
        }
        if(typeof key==='string')return effects.find(effect=>effect.name===key)?.view ?? null;
        throw Error('Effect lookup needs an index or custom name');
    }
    function updateEffectProperties() {
        for(const effect of effectRecords.values())if(!effect.overridden) {
            const value=resolvedProperty(effect.property);
            effect.visible=value!==false && value!==0;
        }
    }
    function effectSnapshot() {
        return Object.fromEntries([...effectRecords.values()].filter(effect=>effect.overridden).map(effect=>[effect.path,effect.visible]));
    }
"""#
