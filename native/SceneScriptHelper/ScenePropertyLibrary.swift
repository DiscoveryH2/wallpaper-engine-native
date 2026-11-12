import Foundation

/// Author code receives copies of vector properties; only explicit assignments
/// publish a setting. One complete snapshot joins the existing frame reply.
let sceneScriptScenePropertyLibrary = #"""
    const scenePropertyRecords=new Map();
    function checkedSceneProperty(record,value) {
        function scalar(raw) {
            if(typeof raw!=='number'||!Number.isFinite(raw)||Math.abs(raw)>3.4028234663852886e38)
                throw Error('Scene property requires finite Float values');
            return Math.fround(raw);
        }
        if(record.kind==='boolean') {
            if(typeof value!=='boolean')throw Error('Scene property requires a boolean');
            return value;
        }
        if(record.kind==='number')return scalar(value);
        if(record.kind==='vec3') {
            const v=value instanceof Vec3?value:Array.isArray(value)&&value.length===3?new Vec3(...value):null;
            if(!v)throw Error('Scene color requires a Vec3');
            return new Vec3(scalar(v.x),scalar(v.y),scalar(v.z));
        }
        throw Error('Unknown scene property type');
    }
    function loadSceneProperties(metadata) {
        if(!metadata||typeof metadata!=='object'||Object.keys(metadata).length!==19)throw Error('Invalid scene property inventory');
        for(const [key,entry] of Object.entries(metadata)) {
            if(!entry||!['boolean','number','vec3'].includes(entry.kind))throw Error('Invalid scene property descriptor');
            const record={kind:entry.kind,property:entry.property,overridden:false};
            record.value=checkedSceneProperty(record,entry.value);
            scenePropertyRecords.set(key,record);
        }
    }
    function publishSceneProperty(key,value) {
        const record=scenePropertyRecords.get(key);
        if(!record)throw Error('Unsupported thisScene property: '+String(key));
        record.value=checkedSceneProperty(record,value);record.overridden=true;
        for(const binding of bindings)if(binding.sceneProperty===key) {
            binding.value=copy(record.value);
            if(binding.timeline)binding.timelineOverride=true;
        }
    }
    function updateSceneProperties() {
        for(const [key,record] of scenePropertyRecords)if(!record.overridden&&!timelineAnimations.has('/general/'+key)) {
            record.value=checkedSceneProperty(record,initial(resolvedProperty(record.property),key));
        }
    }
    function updateSceneTimeline(path,value) {
        if(!path.startsWith('/general/'))return;
        const record=scenePropertyRecords.get(path.slice('/general/'.length));
        if(record&&!record.overridden)record.value=checkedSceneProperty(record,initial(value,path.slice('/general/'.length)));
    }
    function scenePropertySnapshot() {
        const result=Object.create(null);
        for(const [key,record] of scenePropertyRecords)if(record.overridden) {
            result[key]=record.kind==='vec3'?[record.value.x,record.value.y,record.value.z]:record.value;
        }
        return result;
    }
    function makeSceneView(methods) {
        return new Proxy(Object.freeze(methods),{
            get:(target,key)=>{
                const record=scenePropertyRecords.get(key);
                if(record)return copy(record.value);
                if(Object.hasOwn(target,key))return target[key];
                throw Error('Unsupported thisScene property: '+String(key));
            },
            set:(target,key,value)=>{publishSceneProperty(key,value);return true;},
            defineProperty:()=>{throw Error('Cannot redefine scene properties');},
            deleteProperty:()=>{throw Error('Cannot delete scene properties');}
        });
    }
"""#
