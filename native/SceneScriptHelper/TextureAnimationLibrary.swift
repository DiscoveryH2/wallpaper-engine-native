import Foundation

// Development-owned implementation of the documented ITextureAnimation API.
// This code runs inside the same isolated JavaScriptCore VM as wallpaper scripts.
let sceneScriptTextureAnimationLibrary = #"""
    function textureAnimation(metadata) {
        if(!metadata)return null;
        const durations=metadata.durations;
        if(!Array.isArray(durations)||!durations.length||durations.length>4096||
           !durations.every(value=>Number.isFinite(value)&&value>=0&&value<=3600))throw Error('Invalid texture animation durations');
        const duration=durations.reduce((a,b)=>a+b,0);
        let joined=true,playing=true,position=0,anchor=0,rate=1,alive=true,staticFrame=0;
        const normalize=t=>duration>0?((t%duration)+duration)%duration:0;
        const current=()=>normalize(joined?engine.runtime:position+(playing?(engine.runtime-anchor)*rate:0));
        function detach() {
            if(!alive)throw Error('Texture animation owner has been removed');
            position=current();anchor=engine.runtime;
            if(joined){playing=true;rate=1;joined=false;}
        }
        const view=Object.freeze({
            get frameCount(){return durations.length;},
            get duration(){return duration;},
            get rate(){return joined?1:rate;},
            set rate(value){
                if(typeof value!=='number'||!Number.isFinite(value)||Math.abs(value)>100)throw Error('Texture animation rate must be finite and within -100...100');
                detach();rate=value;
            },
            play(){detach();playing=true;},
            pause(){detach();playing=false;},
            stop(){detach();position=0;staticFrame=0;playing=false;},
            isPlaying(){return joined||playing;},
            getFrame(){
                if(duration===0)return staticFrame;
                let time=current();
                for(let i=0;i<durations.length;i++){if(time<durations[i])return i;time-=durations[i];}
                return durations.length-1;
            },
            setFrame(frame){
                if(typeof frame!=='number'||!Number.isFinite(frame)||frame<0||frame>=durations.length)throw Error('Texture animation frame is outside its finite frame range');
                detach();if(duration===0){staticFrame=Math.floor(frame);return;}
                position=durations.slice(0,Math.floor(frame)).reduce((a,b)=>a+b,0);
            },
            join(){if(!alive)throw Error('Texture animation owner has been removed');joined=true;playing=true;position=0;anchor=0;rate=1;staticFrame=0;}
        });
        return {view,retire:()=>{alive=false;},snapshot:()=>duration===0?({joined,playing,position,anchor,rate,staticFrame}):({joined,playing,position,anchor,rate})};
    }
"""#
