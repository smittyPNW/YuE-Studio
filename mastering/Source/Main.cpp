#include <JuceHeader.h>
#include "audio/OfflineRenderer.h"
#include "audio/MasteringAdvisor.h"
#include "presets/PresetManager.h"
#include <atomic>
#include <csignal>
#include <iostream>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

namespace {
std::atomic<bool> cancelled { false };
void cancelHandler(int) { cancelled.store(true); }
juce::var object(std::initializer_list<std::pair<const char*,juce::var>> values) {
    auto* result = new juce::DynamicObject();
    for (const auto& v : values) result->setProperty(v.first,v.second);
    return juce::var(result);
}
void emit(const juce::var& value) { std::cout << juce::JSON::toString(value,true).toStdString() << std::endl; }
juce::var analysis(const LoudnessAnalyzer::Result& a) {
    return object({{"lufs",a.integratedLufs},{"truePeak",a.truePeakDb},{"samplePeak",a.samplePeakDb}});
}
struct Lease {
    int fd = -1;
    explicit Lease(const juce::File& file) {
        file.getParentDirectory().createDirectory();
        fd = ::open(file.getFullPathName().toRawUTF8(), O_CREAT | O_RDWR, 0600);
        if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) throw std::runtime_error("Music generation or another mastering job is still running. Wait for it to finish.");
    }
    ~Lease() { if(fd>=0) { flock(fd,LOCK_UN); ::close(fd); } }
};
void validate(const ParameterState& p) {
    auto bound=[](float v,float low,float high) { if(!std::isfinite(v)||v<low||v>high) throw std::runtime_error("A mastering setting is outside its supported range."); };
    for(float v:{p.monoLow,p.monoHigh,p.width,p.punch,p.deChirp,p.deEsser,p.bass,p.mud,p.mid,p.treble,p.warmth,p.analogLife,p.warmExciter,p.airExciter,p.tapeHiss}) bound(v,0,1);
    bound(p.masterVolDb,-12,18); bound(p.targetLufs,-30,-5); bound(p.ceilingDb,-12,0); bound(p.fadeInSec,0,10); bound(p.fadeOutSec,0,15);
    if((int)p.finalCharacter<0||(int)p.finalCharacter>4) throw std::runtime_error("Unknown final character.");
    for(const auto& b:p.eq) { bound(b.frequencyHz,20,22000); bound(b.gainDb,-18,18); bound(b.q,0.1f,12); if(b.type<0||b.type>4) throw std::runtime_error("Unknown EQ filter."); }
}
juce::var patchDifference(const juce::var& before,const juce::var& after) {
    if(before.getDynamicObject()!=nullptr && after.getDynamicObject()!=nullptr) {
        auto patch=object({});
        for(const auto& value:after.getDynamicObject()->getProperties()) {
            auto old=before.getProperty(value.name,{});
            if(juce::JSON::toString(old,true)!=juce::JSON::toString(value.value,true))
                patch.getDynamicObject()->setProperty(value.name,patchDifference(old,value.value));
        }
        return patch;
    }
    if(before.isArray() && after.isArray()) {
        auto patch=object({});
        for(int i=0;i<after.size();++i)
            if(juce::JSON::toString(before[i],true)!=juce::JSON::toString(after[i],true))
                patch.getDynamicObject()->setProperty(juce::Identifier(juce::String(i)),patchDifference(before[i],after[i]));
        return patch;
    }
    return after;
}
void catalog() {
    PresetManager presets; juce::Array<juce::var> entries;
    auto names=presets.getPresetNames();
    for(int i=0;i<presets.getBuiltInCount();++i) {
        ParameterState p; presets.loadPreset(names[i],p);
        entries.add(object({{"name",names[i]},{"description",presets.getPresetDescription(names[i])},{"parameters",p.toVar()}}));
    }
    juce::Array<juce::var> repairs;
    for(auto name:{"Stereo","Bass","Mid","High"}) {
        ParameterState p;
        if(juce::String(name)=="Stereo") p.applyQuickFixStereo();
        if(juce::String(name)=="Bass") p.applyQuickFixBass();
        if(juce::String(name)=="Mid") p.applyQuickFixMid();
        if(juce::String(name)=="High") p.applyQuickFixHigh();
        auto patch=patchDifference(ParameterState{}.toVar(),p.toVar());
        repairs.add(object({{"name",name},{"patch",patch}}));
    }
    emit(object({{"presets",entries},{"repairs",repairs},{"defaults",ParameterState{}.toVar()}}));
}
}
int main(int argc,char** argv) {
    std::signal(SIGTERM,cancelHandler); std::signal(SIGINT,cancelHandler);
    try {
        if(argc==2 && juce::String(argv[1])=="--catalog") { catalog(); return 0; }
        if(argc!=2) throw std::runtime_error("Provide a mastering request JSON file.");
        auto request=juce::JSON::parse(juce::File(argv[1]));
        if(request.getDynamicObject()==nullptr) throw std::runtime_error("Invalid mastering request.");
        Lease lease(juce::File(request["lock"].toString()));
        juce::File input(request["input"].toString());
        emit(object({{"event","progress"},{"message","Reading audio"},{"fraction",0.02}}));
        // Validate dimensions before Studio Mastering allocates the decoded source.
        juce::AudioFormatManager formats; formats.registerBasicFormats();
        std::unique_ptr<juce::AudioFormatReader> reader(formats.createReaderFor(input));
        if(!reader || reader->numChannels<1 || reader->numChannels>2 || reader->sampleRate<8000 || reader->sampleRate>192000 || reader->lengthInSamples<=0 || reader->lengthInSamples>120000000)
            throw std::runtime_error("Choose a mono or stereo WAV, AIFF, FLAC, MP3 or M4A file (up to 192 kHz and 120 million frames).");
        reader.reset();
        AudioFileManager files; juce::String error;
        if(!files.load(input,error)) throw std::runtime_error(error.toStdString());
        if(cancelled) throw std::runtime_error("Cancelled. Your source and previous masters are unchanged.");
        ParameterState parameters; parameters.fromVar(request["parameters"]); validate(parameters);
        const auto command=request["command"].toString();
        if(command=="analyze" || command=="smart") {
            emit(object({{"event","progress"},{"message","Listening to the full song"},{"fraction",0.15}}));
            const auto measured=LoudnessAnalyzer::analyze(files.getBuffer(),files.getSampleRate(),&cancelled);
            if(cancelled) throw std::runtime_error("Cancelled. Your settings are unchanged.");
            juce::String message="Source measured. Choose a style, or let Smart Master suggest a gentle starting point.";
            if(command=="smart") message=MasteringAdvisor::explanation(MasteringAdvisor::applyEasyFix(parameters,measured));
            emit(object({{"event","result"},{"analysis",analysis(measured)},{"parameters",parameters.toVar()},{"message",message},{"duration",files.getDurationSec()},{"sampleRate",files.getSampleRate()},{"channels",files.getNumChannels()}}));
            return 0;
        }
        if(command!="render") throw std::runtime_error("Unknown mastering action.");
        juce::File output(request["output"].toString());
        if(output.exists() || output==input || !output.hasFileExtension("wav")) throw std::runtime_error("Use a new WAV destination; existing music is never overwritten.");
        output.getParentDirectory().createDirectory();
        OfflineRenderer::Options options; options.outputFile=output; options.format=ExportFormat::Kind::wav; options.qualityIndex=0; options.targetSampleRate=0;
        options.presetName=request["presetName"].toString(); options.metadata=files.getMetadata();
        if(request["title"].toString().isNotEmpty()) options.metadata.title=request["title"].toString();
        if(request["artist"].toString().isNotEmpty()) options.metadata.artist=request["artist"].toString();
        float last=-1;
        const bool success=OfflineRenderer::render(files,parameters,options,error,[&](float fraction){
            if(fraction-last>=0.005f || fraction>=1) { last=fraction; emit(object({{"event","progress"},{"message",fraction<0.55f && parameters.normalizeActive ? "Measuring and matching loudness" : (fraction<0.9f ? "Rendering full-quality master" : "Verifying the delivered audio")},{"fraction",0.04+fraction*0.92}})); }
        },[]{return cancelled.load();});
        if(!success) throw std::runtime_error(error.toStdString());
        files.clear();
        AudioFileManager delivery;
        if(!delivery.load(output,error)) throw std::runtime_error(error.toStdString());
        const auto measured=LoudnessAnalyzer::analyze(delivery.getBuffer(),delivery.getSampleRate(),&cancelled);
        if(cancelled) throw std::runtime_error("Cancelled. A completed render may be present in the session folder.");
        auto result=object({{"event","result"},{"output",output.getFullPathName()},{"analysis",analysis(measured)},{"parameters",parameters.toVar()},{"duration",delivery.getDurationSec()},{"sampleRate",delivery.getSampleRate()},{"channels",delivery.getNumChannels()},{"message","Master ready. Compare Before and After, then export."}});
        auto manifest=output.withFileExtension("json"); juce::TemporaryFile temp(manifest);
        if(!temp.getFile().replaceWithText(juce::JSON::toString(result))||!temp.overwriteTargetFileWithTemporary()) throw std::runtime_error("Audio is saved, but its session report could not be written.");
        emit(result); return 0;
    } catch(const std::exception& e) { emit(object({{"event",cancelled ? "cancelled" : "error"},{"message",juce::String(e.what())}})); return cancelled ? 130 : 1; }
}
