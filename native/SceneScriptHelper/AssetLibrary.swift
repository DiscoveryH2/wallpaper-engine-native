import Foundation

let sceneScriptAssetLibrary = #"""
    function registerAsset(file, option) {
        if(!timelineModuleLoading)throw Error('registerAsset is only available in module global scope');
        if(typeof file!=='string'||!file.length||file.length>4096)throw Error('Expected a bounded asset path string');
        if(option!==undefined&&typeof option!=='boolean')throw Error('Asset registration option must be boolean');
        const reply=JSON.parse(nativeHostRequest(JSON.stringify({method:'registerAsset',
            arguments:{file,option},scope:'module',bindingKey:timelineBinding?.key})));
        if(reply.ok!==true)throw Error(reply.error||'Native asset registration failed');
        if(reply.value!==file)throw Error('Native asset registration returned an invalid handle');
        return reply.value;
    }
    engine.registerAsset=registerAsset;
"""#
