import Foundation

/// Numeric material objects share one canonical property record with direct
/// bindings. Copies returned by getters cannot mutate another script's state.
let sceneScriptMaterialLibrary = #"""
    const materialRecords = new Map();
    const materialProperties = new Map();
    function materialComponents(value,count) {
        const result=typeof value==='number'?[value]:
            Array.isArray(value)?value.slice():value instanceof Vector?dimensions(value).map(key=>value[key]):null;
        if(!result||result.length!==count||!result.every(x=>typeof x==='number'&&Number.isFinite(x)&&Math.abs(x)<=16384))
            throw Error('Material value must have the declared dimension and finite components within -16384...16384');
        return result;
    }
    function materialValue(components) {
        return components.length===1?components[0]:components.length===2?new Vec2(...components):
            components.length===3?new Vec3(...components):new Vec4(...components);
    }
    function publishMaterialValue(property,value) {
        if(!property.owner.alive)throw Error('Material owner has been removed');
        const components=materialComponents(value,property.value.length);
        property.value=components;property.overridden=true;
        for(const binding of bindings)if(binding.key===property.path) {
            binding.value=materialValue(components);if(binding.timeline)binding.timelineOverride=true;
        }
    }
    function materialRecord(data) {
        if(!data||typeof data.path!=='string'||materialRecords.has(data.path)||
           !Array.isArray(data.properties)||data.properties.length>128||materialRecords.size>=8192)
            throw Error('Invalid material metadata');
        const record={alive:true,path:data.path,properties:new Map()};
        for(const item of data.properties) {
            if(typeof item.name!=='string'||typeof item.path!=='string'||record.properties.has(item.name)||
               materialProperties.has(item.path)||!Array.isArray(item.value)||item.value.length<1||item.value.length>4||
               materialProperties.size>=16384)throw Error('Invalid material property metadata');
            const property={...item,value:materialComponents(item.value,item.value.length),overridden:false,owner:record};
            record.properties.set(item.name,property);materialProperties.set(item.path,property);
        }
        record.view=new Proxy(Object.create(null),{
            get:(_,key)=>{
                if(!record.alive)throw Error('Material owner has been removed');
                if(key==='getAnimation')return name=>{
                    if(!record.alive)throw Error('Material owner has been removed');
                    return ownerTimeline(name,undefined,record.path.slice(1)+'/constantshadervalues');
                };
                const property=record.properties.get(key);
                if(!property)throw Error('Unsupported material property: '+String(key));
                return materialValue(property.value);
            },
            set:(_,key,value)=>{
                const property=record.properties.get(key);
                if(!property)throw Error('Unsupported material write: '+String(key));
                publishMaterialValue(property,value);return true;
            },
            ownKeys:()=>[...record.properties.keys()],
            getOwnPropertyDescriptor:(_,key)=>record.properties.has(key)?{configurable:true,enumerable:true}:undefined
        });
        materialRecords.set(record.path,record);return record;
    }
    function findMaterial(materials,index) {
        if(!materials)throw Error('Material objects are not available in this rendering backend');
        if(!Number.isInteger(index)||index<0)throw Error('Material index must be a non-negative integer');
        return materials[index]?.view ?? null;
    }
    function setMaterialProperty(materials,name,value) {
        if(!materials)throw Error('Material objects are not available in this rendering backend');
        if(typeof name!=='string'||name.length>256)throw Error('Material property name must be a bounded string');
        const count=typeof value==='number'?1:value instanceof Vector?dimensions(value).length:Array.isArray(value)?value.length:0;
        if(count<1||count>4)throw Error('Material broadcast requires a number or numeric vector');
        materialComponents(value,count);
        // The reference broadcast visits every material but only calls a
        // property setter when its type matches the supplied scalar/vector.
        const matches=materials.map(material=>material.properties.get(name)).filter(p=>p&&p.value.length===count);
        // Validate all matched consumers before any write, including dimensions.
        const prepared=matches.map(property=>[property,materialComponents(value,property.value.length)]);
        for(const [property,components] of prepared)publishMaterialValue(property,components);
    }
    function updateMaterialProperties() {
        for(const property of materialProperties.values())if(!property.overridden&&!timelineAnimations.has(property.path)) {
            const raw=resolvedProperty(property.property);
            const parts=typeof raw==='string'?raw.trim().split(/[\s,]+/).map(Number):raw;
            property.value=materialComponents(parts,property.value.length);
        }
    }
    function materialSnapshot() {
        return Object.fromEntries([...materialProperties.values()].filter(p=>p.overridden).map(p=>[p.path,p.value]));
    }
"""#
