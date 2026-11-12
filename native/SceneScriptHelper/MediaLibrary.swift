import Foundation

let sceneScriptMediaLibrary = #"""
    let mediaSnapshot=null;
    const mediaDeliveryCounts=Object.create(null);
    const mediaEventNames=['mediaStatusChanged','mediaPropertiesChanged','mediaThumbnailChanged','mediaPlaybackChanged','mediaTimelineChanged'];
    function deliverMedia(snapshot,recipients=bindings.slice(),force=false) {
        if(!snapshot || !Number.isSafeInteger(snapshot.revision) || snapshot.revision<0 ||
           typeof snapshot.enabled!=='boolean' || typeof snapshot.observed!=='boolean' || ![0,1,2].includes(snapshot.state) ||
           typeof snapshot.thumbnailID!=='string' || snapshot.thumbnailID.length>100 || !Number.isSafeInteger(snapshot.itemSequence) || snapshot.itemSequence<0 ||
           typeof snapshot.properties?.title!=='string' || snapshot.properties.title.length>2051 ||
           typeof snapshot.properties?.artist!=='string' || snapshot.properties.artist.length>2051 ||
           typeof snapshot.thumbnail?.hasThumbnail!=='boolean')throw Error('Invalid native media snapshot');
        if(mediaSnapshot && snapshot.revision<mediaSnapshot.revision)throw Error('Media revision moved backwards');
        if(!force && mediaSnapshot && snapshot.revision===mediaSnapshot.revision)return;
        const old=force?null:mediaSnapshot;
        function emit(name,event) {
            // A wallpaper binding may mutate its event object; each handler
            // receives a separate payload and independent colour vectors.
            let delivered=0;
            for(const binding of recipients) {
                if(binding.disabled || typeof binding.exports[name]!=='function')continue;
                const payload={...event};
                if(name==='mediaThumbnailChanged')for(const key of ['primaryColor','secondaryColor','tertiaryColor','textColor','highContrastColor']) {
                    const color=event[key];
                    if(!Array.isArray(color)||color.length!==3||!color.every(x=>Number.isFinite(x)&&x>=0&&x<=1))throw Error('Invalid media colour');
                    payload[key]=new Vec3(...color);
                }
                invoke(binding,name,payload);delivered++;
            }
            if(delivered)mediaDeliveryCounts[name]=Math.min(1e9,(mediaDeliveryCounts[name]||0)+delivered);
        }
        // This is the host's documented ordering, not a claim about Windows
        // event order: data and colours are available before transport/update.
        if(!old || old.enabled!==snapshot.enabled)emit('mediaStatusChanged',{enabled:snapshot.enabled});
        // Enabling a source before its first successful read does not invent a
        // player state. Disabled is an intentional empty presentation state.
        if(snapshot.enabled&&!snapshot.observed){mediaSnapshot=snapshot;return;}
        const initial=!old || (snapshot.observed&&!old.observed);
        const changedItem=!old || old.itemSequence!==snapshot.itemSequence;
        if(initial || changedItem || JSON.stringify(old.properties)!==JSON.stringify(snapshot.properties))emit('mediaPropertiesChanged',snapshot.properties);
        if(initial || old.thumbnailID!==snapshot.thumbnailID)emit('mediaThumbnailChanged',snapshot.thumbnail);
        if(initial || old.state!==snapshot.state || changedItem)emit('mediaPlaybackChanged',{state:snapshot.state});
        const timeline=snapshot.timeline;
        if(timeline && Number.isFinite(timeline.duration)&&timeline.duration>0&&Number.isFinite(timeline.position)&&timeline.position>=0&&
           (initial || changedItem || JSON.stringify(old.timeline)!==JSON.stringify(timeline)))emit('mediaTimelineChanged',timeline);
        mediaSnapshot=snapshot;
    }
"""#
