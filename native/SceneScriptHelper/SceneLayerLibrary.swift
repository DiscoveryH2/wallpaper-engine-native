import Foundation

let sceneScriptSceneLayerLibrary = #"""
    const sceneLayerHandles=new WeakMap();
    let sceneLayerOrder=[];
    function installSceneLayers() {
        sceneLayerOrder=layers.slice();
        for(const layer of layers)sceneLayerHandles.set(layer.view,layer);
    }
    function findSceneLayer(key,handle=true) {
        // The reference adapter uses Uint32Value for numeric scene indices.
        if(typeof key==='number')return sceneLayerOrder[key>>>0]??null;
        if(typeof key==='string') {
            const named=sceneLayerOrder.find(layer=>layer.name===key);
            if(named)return named;
            // Name lookup precedes the reference's decimal strtoull ID fallback.
            const match=/^[ \t\n\r\f\v]*([+-]?)([0-9]+)/.exec(key);
            const maximum=(1n<<64n)-1n;
            let id=match?BigInt(match[2]):0n;
            if(id>maximum)id=maximum;
            else if(match?.[1]==='-')id=BigInt.asUintN(64,-id);
            return sceneLayerOrder.find(layer=>layer.id===id.toString())??null;
        }
        return handle&&key!==null&&(typeof key==='object'||typeof key==='function')?(sceneLayerHandles.get(key)?.alive?sceneLayerHandles.get(key):null):null;
    }
    function getSceneLayer(key) { return findSceneLayer(key)?.view??null; }
    function getSceneLayerIndex(key) {
        const layer=findSceneLayer(key);return layer?sceneLayerOrder.indexOf(layer):-1;
    }
    function getInitialLayerConfig(key) {
        const layer=findSceneLayer(key);return layer?JSON.parse(layer.initialConfig):null;
    }
    function sortSceneLayer(key,index) {
        const layer=findSceneLayer(key);
        if(!layer||typeof index!=='number')return false;
        index=Math.min(index>>>0,sceneLayerOrder.length-1);
        const previous=sceneLayerOrder.indexOf(layer);
        if(previous!==index){sceneLayerOrder.splice(previous,1);sceneLayerOrder.splice(index,0,layer);}
        return true;
    }
"""#
