// These are our implementations of the documented SceneScript numeric APIs.
// The string is compiled into the helper; there is no runtime JS dependency.
let sceneScriptStandardLibrary = #"""
    const clamp = (x,lo,hi) => Math.min(hi,Math.max(lo,x));
    const smoothStep = (lo,hi,x) => {
        const t=lo===hi?(x<lo?0:1):clamp((x-lo)/(hi-lo),0,1);
        return t*t*(3-2*t);
    };
    const dimensions = value => value instanceof Vec4 ? ['x','y','z','w'] : value instanceof Vec3 ? ['x','y','z'] : ['x','y'];
    const components = (args,size) => {
        if(!args.length)return Array(size).fill(0);
        const a=args[0];
        if(typeof a==='string')return a.trim().split(/[\s,]+/).slice(0,size).map(Number).concat([0,0,0]).slice(0,size);
        if(a && typeof a==='object')return ['x','y','z','w'].slice(0,size).map((key,i)=>Number(a[key] ?? a[i] ?? (size>=3 && i===size-1 && args.length>1?args[1]:0)));
        if(args.length===1)return Array(size).fill(Number(a));
        return Array.from({length:size},(_,i)=>Number(args[i] ?? 0));
    };
    class Vector {
        _map(fn) { return new this.constructor(...dimensions(this).map((key,i)=>fn(this[key],key,i))); }
        _zip(other,fn) { const v=new this.constructor(other); return this._map((x,key)=>fn(x,v[key])); }
        copy() { return new this.constructor(this); }
        lengthSqr() { return this.dot(this); }
        length() { return Math.sqrt(this.lengthSqr()); }
        distanceSqr(v) { return this.subtract(v).lengthSqr(); }
        distance(v) { return Math.sqrt(this.distanceSqr(v)); }
        normalize() { const n=this.length(); return n===0?new this.constructor():this.divide(n); }
        equals(v) { const b=new this.constructor(v); return dimensions(this).every(k=>Math.abs(this[k]-b[k])<=1e-6); }
        isFinite() { return dimensions(this).every(k=>Number.isFinite(this[k])); }
        negate() { return this._map(x=>-x); }
        add(v) { return this._zip(v,(a,b)=>a+b); }
        subtract(v) { return this._zip(v,(a,b)=>a-b); }
        multiply(v) { return this._zip(v,(a,b)=>a*b); }
        divide(v) { return this._zip(v,(a,b)=>a/b); }
        dot(v) { const b=new this.constructor(v); return dimensions(this).reduce((n,k)=>n+this[k]*b[k],0); }
        reflect(n) { return this.subtract(n.multiply(2*this.dot(n))); }
        mix(v,t) { return this._zip(v,(a,b)=>a+(b-a)*t); }
        min(v) { return this._zip(v,Math.min); }
        max(v) { return this._zip(v,Math.max); }
        clamp(lo,hi) { return this.max(lo).min(hi); }
        abs() { return this._map(Math.abs); }
        sign() { return this._map(Math.sign); }
        round() { return this._map(Math.round); }
        floor() { return this._map(Math.floor); }
        ceil() { return this._map(Math.ceil); }
        fract() { return this._map(x=>x-Math.floor(x)); }
        mod(v) { return this._zip(v,(a,b)=>a-b*Math.floor(a/b)); }
        step(edge) { return this._zip(edge,(a,b)=>a<b?0:1); }
        smoothStep(lo,hi) { const a=new this.constructor(lo),b=new this.constructor(hi);return this._map((x,k)=>smoothStep(a[k],b[k],x)); }
        toString() { return dimensions(this).map(k=>this[k]).join(' '); }
    }
    class Vec2 extends Vector {
        constructor(...args) { super();[this.x,this.y]=components(args,2); }
        perpendicular() { return new Vec2(-this.y,this.x); }
    }
    class Vec3 extends Vector {
        constructor(...args) { super();[this.x,this.y,this.z]=components(args,3); }
        cross(v) { return new Vec3(this.y*v.z-this.z*v.y,this.z*v.x-this.x*v.z,this.x*v.y-this.y*v.x); }
        refract(n,eta) {
            const dot=this.dot(n),k=1-eta*eta*(1-dot*dot);
            return k<0?new Vec3():this.multiply(eta).subtract(n.multiply(eta*dot+Math.sqrt(k)));
        }
        project(v) { const d=v.lengthSqr();return d===0?new Vec3():v.multiply(this.dot(v)/d); }
        angleBetween(v) { const d=this.length()*v.length();return d===0?0:Math.acos(clamp(this.dot(v)/d,-1,1))*180/Math.PI; }
        static fromSpherical(r,theta,phi) {
            const t=theta*Math.PI/180,p=phi*Math.PI/180;
            return new Vec3(r*Math.sin(t)*Math.cos(p),r*Math.cos(t),r*Math.sin(t)*Math.sin(p));
        }
        toSpherical() { const r=this.length();return r===0?new Vec3():new Vec3(r,Math.acos(clamp(this.y/r,-1,1))*180/Math.PI,Math.atan2(this.z,this.x)*180/Math.PI); }
    }
    class Vec4 extends Vector {
        constructor(...args) { super();[this.x,this.y,this.z,this.w]=components(args,4); }
    }
    const WEMath=Object.freeze({deg2rad:Math.PI/180,rad2deg:180/Math.PI,smoothStep,mix:(a,b,t)=>a+(b-a)*t});
    const WEVector=Object.freeze({
        angleVector2:angle=>new Vec2(Math.cos(angle*Math.PI/180),Math.sin(angle*Math.PI/180)),
        vectorAngle2:v=>Math.atan2(v.y,v.x)*180/Math.PI
    });
    const WEColor=Object.freeze({
        normalizeColor:v=>new Vec3(v).divide(255),expandColor:v=>new Vec3(v).multiply(255),
        rgb2hsv:v=>{
            const r=v.x,g=v.y,b=v.z,hi=Math.max(r,g,b),lo=Math.min(r,g,b),delta=hi-lo;
            let hue=0;
            if(delta!==0)hue=(hi===r?(g-b)/delta:hi===g?(b-r)/delta+2:(r-g)/delta+4)/6;
            return new Vec3((hue+1)%1,hi===0?0:delta/hi,hi);
        },
        hsv2rgb:v=>{
            const h=((v.x%1)+1)%1*6,s=v.y,brightness=v.z;
            const channel=n=>brightness*(1-s*clamp(Math.min((n+h)%6,4-(n+h)%6),0,1));
            return new Vec3(channel(5),channel(3),channel(1));
        }
    });
    const builtinModules=Object.freeze({WEMath,WEColor,WEVector});
"""#
