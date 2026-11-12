import Foundation

/// Static scene camera state. Camera objects and paths are resolved separately
/// by the renderer and never fed back into this scripting snapshot.
let sceneScriptCameraLibrary = #"""
    let staticCamera;
    let cameraReads=0,cameraWrites=0,cameraOverflow=false;
    function cameraNumber(value) {
        if(typeof value!=='number'||!Number.isFinite(value)||Math.abs(value)>3.4028234663852886e38)
            throw Error('Camera components must be finite Float values');
        return Math.fround(value);
    }
    function cameraVector(value) {
        if(!value||typeof value!=='object')throw Error('Camera transforms require Vec3 components');
        return new Vec3(cameraNumber(value.x),cameraNumber(value.y),cameraNumber(value.z));
    }
    function cameraCopy(value) {
        return {eye:value.eye.copy(),center:value.center.copy(),up:value.up.copy(),zoom:value.zoom};
    }
    function cameraValidate(value) {
        const direction=value.center.subtract(value.eye),length=Math.hypot(direction.x,direction.y,direction.z);
        if(!Number.isFinite(length)||length===0)throw Error('Camera eye and center must define a direction');
        const x=direction.x/length,y=direction.y/length,z=direction.z/length,u=value.up;
        const cross=Math.hypot(y*u.z-z*u.y,z*u.x-x*u.z,x*u.y-y*u.x);
        if(!Number.isFinite(cross)||cross===0)throw Error('Camera up must not be parallel to the view');
        return value;
    }
    function installCamera(message) {
        if(message.cameraProtocol!==1)throw Error('Unsupported camera protocol');
        const value=message.camera;
        staticCamera=cameraValidate({eye:cameraVector(value?.eye),center:cameraVector(value?.center),
            up:cameraVector(value?.up),zoom:cameraNumber(value?.zoom)});
        cameraReads=0;cameraWrites=0;cameraOverflow=false;
    }
    function countCameraOperation() {
        if(cameraReads+cameraWrites>=4096){cameraOverflow=true;throw Error('Camera operation limit exceeded');}
    }
    function getCameraTransforms() {
        countCameraOperation();cameraReads++;
        return cameraCopy(staticCamera);
    }
    function setCameraTransforms(value) {
        countCameraOperation();
        if(!value||typeof value!=='object'||Array.isArray(value))throw Error('Expected a CameraTransforms object');
        const next=cameraCopy(staticCamera);
        // REA: the native setter updates only non-null argument pointers.
        // Omitted JS properties leave the corresponding component intact.
        for(const key of ['eye','center','up'])if(value[key]!==undefined)next[key]=cameraVector(value[key]);
        if(value.zoom!==undefined)next.zoom=cameraNumber(value.zoom);
        staticCamera=cameraValidate(next);cameraWrites++;
    }
    function cameraReceipt() {
        if(cameraOverflow)throw Error('Camera operation batch overflow; response not committed');
        return {protocol:1,reads:cameraReads,writes:cameraWrites,transforms:cameraWrites?staticCamera:undefined};
    }
"""#
