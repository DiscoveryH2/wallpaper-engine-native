import Foundation

// Development-owned IVideoTexture implementation. Scene time is provided by
// the host; no wall clock or native AVFoundation object enters JavaScriptCore.
let sceneScriptVideoTextureLibrary = #"""
    const videos=new Map();
    function videoTexture(metadata) {
        if(!metadata)return null;
        const {key,duration}=metadata;
        if(typeof key!=='string'||key.length>1024||!Number.isFinite(duration)||duration<=0||duration>86400)throw Error('Invalid video texture metadata');
        if(videos.has(key))return videos.get(key);
        if(videos.size>=8)throw Error('Video texture limit exceeded');
        let playing=true,loop=true,position=0,anchor=engine.runtime,rate=1,alive=true;
        const callbacks=[];
        const raw=()=>position+(playing?Math.max(0,engine.runtime-anchor)*rate:0);
        const current=()=>loop?raw()%duration:Math.min(duration,raw());
        function active(){if(!alive)throw Error('Video texture has been removed');}
        function freeze(){active();position=current();anchor=engine.runtime;}
        const view=Object.freeze({
            get duration(){return duration;},
            get rate(){return rate;},
            set rate(value){
                if(typeof value!=='number'||!Number.isFinite(value)||value<0||value>16)throw Error('Native video rate supports finite values from 0 to 16');
                freeze();rate=value;
            },
            get loop(){return loop;},
            set loop(value){if(typeof value!=='boolean')throw Error('Video loop must be boolean');freeze();loop=value;},
            play(){freeze();if(position>=duration)position=0;playing=true;},
            pause(){freeze();playing=false;},
            stop(){active();position=0;anchor=engine.runtime;playing=false;},
            isPlaying(){return playing&&(loop||raw()<duration);},
            getCurrentTime(){return current();},
            setCurrentTime(value){
                active();
                if(typeof value!=='number'||!Number.isFinite(value)||value<0||value>duration)throw Error('Video time must be within its duration');
                position=loop&&value===duration?0:value;anchor=engine.runtime;
            },
            addEndedCallback(callback){
                active();
                if(typeof callback!=='function'||callbacks.length>=32)throw Error('Invalid video callback or callback limit exceeded');
                callbacks.push({callback,binding:timelineBinding});
            }
        });
        const record={view,retire:()=>{alive=false;callbacks.length=0;},removeCallbacks:predicate=>{for(let i=callbacks.length-1;i>=0;i--)if(predicate(callbacks[i].binding))callbacks.splice(i,1);},snapshot:()=>({playing,loop,position,anchor,rate}),advance(){
            if(!playing||rate===0)return;
            const time=raw();if(time<duration)return;
            const count=loop?Math.floor(time/duration):1;
            if(count>128)throw Error('Video ended callback catch-up exceeds 128 loops');
            position=loop?time%duration:duration;anchor=engine.runtime;if(!loop)playing=false;
            // Snapshot makes registration/reentrancy bounded and deterministic.
            const listeners=callbacks.slice();
            for(let i=0;i<count;i++)for(const listener of listeners) {
                if(!callbacks.includes(listener))continue;
                // Keep the original plain function invocation. The ownership
                // record is internal and must not become the callback's this.
                try{const callback=listener.callback;withTimelineBinding(listener.binding,()=>callback());}catch(error){callbacks.splice(callbacks.indexOf(listener),1);fail('video ended callback',error);}
            }
        }};
        videos.set(key,record);return record;
    }
    function advanceVideos(){for(const video of videos.values())video.advance();}
    function videoSnapshot(){return Object.fromEntries(Array.from(videos,([key,video])=>[key,video.snapshot()]));}
"""#
