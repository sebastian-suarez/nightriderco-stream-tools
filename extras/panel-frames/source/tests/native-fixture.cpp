#include "panel-frames.hpp"
#include "obs-api.hpp"
#include "runtime.hpp"
#include "PreviewProgramSizeObserver.hpp"
#include <QApplication>
#include <QElapsedTimer>
#include <QDockWidget>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QMainWindow>
#include <QPainter>
#include <QPlatformSurfaceEvent>
#include <QScrollBar>
#include <QWindow>
#include <stdexcept>
#include "fixture-paths.hpp"

static QWidget *frontendWindow = nullptr;
static obs_frontend_event_cb registeredCallback = nullptr;
static const char *runtimeObsVersion = "32.2.2";
extern "C" void *obs_frontend_get_main_window(void) { return frontendWindow; }
extern "C" void obs_frontend_add_event_callback(obs_frontend_event_cb cb, void *) { registeredCallback = cb; }
extern "C" void obs_frontend_remove_event_callback(obs_frontend_event_cb cb, void *) { if (registeredCallback == cb) registeredCallback = nullptr; }
extern "C" const char *obs_get_version_string(void) { return runtimeObsVersion; }
extern "C" bool obs_module_load(void);
extern "C" void obs_module_unload(void);

static QString output;
static void check(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
static void settle() { QElapsedTimer elapsed;elapsed.start();do { QCoreApplication::sendPostedEvents(); QCoreApplication::processEvents(); } while(elapsed.elapsed()<30); }
template <typename Predicate> static void waitUntil(Predicate ready) {
    QElapsedTimer elapsed;elapsed.start();
    while (!ready() && elapsed.elapsed()<1000) { QCoreApplication::sendPostedEvents(); QCoreApplication::processEvents(); }
}
static QString read(const QString &path) { QFile f(path); check(f.open(QIODevice::ReadOnly),"read fixture stylesheet");return QString::fromUtf8(f.readAll()); }

class OBSQTDisplay : public QWidget {
    Q_OBJECT
    Q_PROPERTY(QColor displayBackgroundColor READ color WRITE setColor)
public:
    QColor bg = Qt::black;
    int surfaceDestroyed = 0;
    explicit OBSQTDisplay(QWidget *parent=nullptr) : QWidget(parent) {
        setAttribute(Qt::WA_PaintOnScreen);
        setAttribute(Qt::WA_StaticContents);
        setAttribute(Qt::WA_NoSystemBackground);
        setAttribute(Qt::WA_OpaquePaintEvent);
        setAttribute(Qt::WA_DontCreateNativeAncestors);
        setAttribute(Qt::WA_NativeWindow);
        setSizePolicy(QSizePolicy::Expanding,QSizePolicy::Expanding);
        setMinimumSize(160,120);
        windowHandle()->installEventFilter(this);
    }
    QColor color() const { return bg; }
    void setColor(QColor c) { bg=c;update(); }
    bool eventFilter(QObject *,QEvent *event) override {
        if(event->type()==QEvent::PlatformSurface && static_cast<QPlatformSurfaceEvent *>(event)->surfaceEventType()==QPlatformSurfaceEvent::SurfaceAboutToBeDestroyed) ++surfaceDestroyed;
        return false;
    }
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);p.fillRect(rect(),bg);p.setPen(QColor("#94a8ba"));p.drawText(rect(),Qt::AlignCenter,"Native display fixture");
    }
};
class OBSBasicPreview : public OBSQTDisplay { Q_OBJECT public: using OBSQTDisplay::OBSQTDisplay; };

static QLabel *label(const QString &text,QWidget *parent) {
    auto *l=new QLabel(text,parent);l->setProperty("class","label-preview-title");return l;
}

int main(int argc,char **argv)
{
    QApplication app(argc,argv);
    output=QString::fromUtf8(NRC_EVIDENCE_DIR);
    const QString resources=QCoreApplication::applicationDirPath()+"/../Resources/";
    const QString qss=read(resources+"theme.qss");
    const QString largeQss=read(resources+"theme-large.qss");
    app.setStyleSheet(qss);
    QMainWindow window;window.setWindowTitle("NIGHTRIDERCO Panel Frame Check");
    const QMargins mainBaseline(2,3,4,5);window.setContentsMargins(mainBaseline);
    auto *resolutionDock=new QDockWidget("Resolution",&window);
    auto *resolutionBody=new QWidget;resolutionBody->setMinimumWidth(120);resolutionDock->setWidget(resolutionBody);
    window.addDockWidget(Qt::LeftDockWidgetArea,resolutionDock);
    auto *canvas=new QWidget;canvas->setObjectName("canvasEditor");window.setCentralWidget(canvas);
    auto *row=new QHBoxLayout(canvas);row->setContentsMargins(16,16,16,16);row->setSpacing(16);
    auto *previewHost=new QWidget(canvas);previewHost->setObjectName("previewContainer");row->addWidget(previewHost);
    auto *previewColumn=new QVBoxLayout(previewHost);previewColumn->setContentsMargins(0,0,0,0);previewColumn->setSpacing(0);
    auto *previewTitle=label("Preview: Desktop Auto",previewHost);
    previewTitle->setProperty("nrcMainWindowInset",QString("prior"));
    previewColumn->addWidget(previewTitle);
    auto *grid=new QGridLayout;grid->setContentsMargins(0,0,0,0);grid->setSpacing(0);previewColumn->addLayout(grid);
    auto *preview=new OBSBasicPreview(previewHost);preview->setObjectName("preview");grid->addWidget(preview,1,0,1,2);
    auto *zoom=new QLabel("−   50%   +    Scale to Window",previewHost);zoom->setMinimumHeight(28);grid->addWidget(zoom,2,1);
    auto *scroll=new QScrollBar(Qt::Vertical,previewHost);grid->addWidget(scroll,1,2);
    QWidget *programHost=nullptr;OBSQTDisplay *program=nullptr;QVBoxLayout *programColumn=nullptr;
    QPointer<PreviewProgramSizeObserver> observer;
    auto createProgram=[&]{
        programHost=new QWidget(canvas);row->addWidget(programHost);
        programColumn=new QVBoxLayout(programHost);programColumn->setContentsMargins(0,0,0,0);programColumn->setSpacing(0);
        programColumn->addWidget(label("Program: BRB",programHost));program=new OBSQTDisplay(programHost);programColumn->addWidget(program);
        observer=new PreviewProgramSizeObserver(preview,program,&window);
    };
    createProgram();window.resize(1000,600);window.show();
    QTimer::singleShot(100,&window,[&]{
        QJsonObject result;result["qt_version"]=qVersion();result["platform"]=QGuiApplication::platformName();
        try {
            settle();
            const WId previewId=preview->winId(),programId=program->winId();
            QObject *previewParent=preview->parent(),*programParent=program->parent();
            QLayoutItem *previewItem=grid->itemAt(grid->indexOf(preview));
            QLayoutItem *programItem=programColumn->itemAt(programColumn->indexOf(program));
            const auto initialPreviewRect=preview->geometry(),initialProgramRect=program->geometry();
            const int originalDockTop=resolutionDock->y();
            const int originalPreviewTextTop=previewTitle->mapTo(&window,previewTitle->contentsRect().topLeft()).y();
            auto *programTitle=programHost->findChild<QLabel *>();
            const int originalProgramTextTop=programTitle->mapTo(&window,programTitle->contentsRect().topLeft()).y();
            auto *keeper=new PanelFrames(&window);PanelFrames &frames=*keeper;frames.refresh();settle();
            check(window.contentsMargins()==QMargins(2,11,4,5),"main window adds only owned8px top inset");
            check(resolutionDock->y()==originalDockTop+8,"Resolution moves8px below top bar");
            check(previewTitle->contentsMargins().top()==6 && programTitle->contentsMargins().top()==6,"both titles compensate8px top margin");
            check(previewTitle->contentsMargins().bottom()==14 && programTitle->contentsMargins().bottom()==14,"title bottom margins retained");
            check(previewTitle->mapTo(&window,previewTitle->contentsRect().topLeft()).y()==originalPreviewTextTop && programTitle->mapTo(&window,programTitle->contentsRect().topLeft()).y()==originalProgramTextTop,"horizontal title text top positions retained");
            check(previewTitle->styleSheet().isEmpty() && programTitle->styleSheet().isEmpty(),"no local label stylesheet left behind");
            result["main_top_inset"]=8;result["title_top_margin"]=6;result["title_bottom_margin"]=14;result["horizontal_title_text_position_unchanged"]=true;
            check(frames.panelCount()==2,"two matching panel hosts");
            check(preview->parent()==previewParent && program->parent()==programParent,"display parents retained");
            check(preview->winId()==previewId && program->winId()==programId,"native handles retained");
            check(preview->surfaceDestroyed==0 && program->surfaceDestroyed==0,"no native surface destruction");
            check(grid->itemAt(grid->indexOf(preview))==previewItem && programColumn->itemAt(programColumn->indexOf(program))==programItem,"original layout items retained");
            check(preview->color()==QColor("#0b1118") && program->color()==preview->color(),"matching display colors");
            auto *pf=previewHost->findChild<QFrame *>("nrcPreviewFrame");
            auto *gf=programHost->findChild<QFrame *>("nrcProgramFrame");
            check(pf && gf,"both underlays exist");
            check(pf->testAttribute(Qt::WA_TransparentForMouseEvents) && gf->testAttribute(Qt::WA_TransparentForMouseEvents),"underlays pass through mouse events");
            result["qt_promotes_underlay_to_native"]=pf->testAttribute(Qt::WA_NativeWindow);
            // Native window creation can outlast settle() before the queued geometry update runs.
            waitUntil([&]{ return pf->geometry().contains(scroll->geometry()) && pf->geometry().contains(zoom->geometry()); });
            check(pf->geometry().contains(scroll->geometry()) && pf->geometry().contains(zoom->geometry()),"Preview frame encloses scrollbars and zoom");
            check(preview->x()-pf->x()==12 && preview->y()-pf->y()==12,"matching top and side insets");
            check(gf->rect().width()-program->width()==24,"Program symmetric side insets");
            auto frameImage=pf->grab().toImage();
            const qreal dpr=frameImage.devicePixelRatio();
            check(frameImage.pixelColor(int(0*dpr),int(20*dpr))==QColor("#2b3948"),"outline painted outside native child");
            check(frameImage.pixelColor(int(0*dpr),int(0*dpr))!=QColor("#2b3948"),"outline corner rounded");
            const QMargins margins=previewHost->contentsMargins();const int itemCount=programColumn->count();
            for(int i=0;i<5;++i)frames.refresh();settle();
            check(previewHost->contentsMargins()==margins && programColumn->count()==itemCount,"repeated refresh does not accumulate insets");
            check(window.contentsMargins()==QMargins(2,11,4,5),"main inset does not accumulate");
            QString legacy=qss;legacy.replace("nrcMainWindowInset","legacyInsetMarker");
            app.setStyleSheet(legacy);frames.refresh();settle();
            check(frames.panelCount()==2 && window.contentsMargins()==mainBaseline,"legacy theme keeps frames and removes main inset");
            check(previewTitle->property("nrcMainWindowInset").toString()=="prior" && !programTitle->property("nrcMainWindowInset").isValid(),"existing and absent label properties restored");
            check(previewTitle->contentsMargins().top()==14 && programTitle->contentsMargins().top()==14,"legacy theme title margins restored");
            app.setStyleSheet(qss);frames.refresh();settle();
            window.resize(820,480);settle();
            check(pf->width()==previewHost->width() && gf->width()==programHost->width(),"underlays track resizing");
            check(std::abs(preview->width()-program->width())<=1,"OBS observer equalizes native display widths");
            preview->hide();settle();check(pf->isHidden() && !gf->isHidden(),"hidden Preview hides only its frame");
            preview->show();settle();check(!pf->isHidden() && preview->winId()==previewId,"Preview return retains native handle");
            for(QWidget *host : {previewHost,programHost})host->findChild<QLabel *>()->hide();
            settle();check(preview->y()-pf->y()==12 && program->y()-gf->y()==12,"hidden titles keep frame inset");
            for(QWidget *host : {previewHost,programHost})host->findChild<QLabel *>()->show();
            row->setDirection(QBoxLayout::TopToBottom);window.resize(820,800);settle();
            check(std::abs(preview->height()-program->height())<=1,"OBS observer equalizes vertical display heights");
            result["vertical_preview_text_top"]=previewTitle->mapTo(&window,previewTitle->contentsRect().topLeft()).y();
            result["vertical_program_text_top"]=programTitle->mapTo(&window,programTitle->contentsRect().topLeft()).y();
            check(pf->geometry().contains(scroll->geometry()) && pf->geometry().contains(zoom->geometry()),"vertical frame encloses Preview controls");
            check(preview->winId()==previewId && program->winId()==programId && preview->surfaceDestroyed==0 && program->surfaceDestroyed==0,"hidden and vertical cases preserve native surfaces");
            row->setDirection(QBoxLayout::LeftToRight);window.resize(820,480);settle();
            window.grab().save(output+"/native-frames.png");
            app.setStyleSheet(qss.split("QFrame#nrcPreviewFrame").front());frames.refresh();settle();
            check(frames.panelCount()==0 && previewHost->contentsMargins()==QMargins(),"theme switch restores margins");
            check(window.contentsMargins()==mainBaseline && previewTitle->property("nrcMainWindowInset").toString()=="prior","theme disable restores main margin and title property");
            check(grid->rowMinimumHeight(0)==0 && programColumn->count()==2,"theme switch removes only inserted spacing");
            check(preview->winId()==previewId && program->winId()==programId && preview->surfaceDestroyed==0 && program->surfaceDestroyed==0,"restoration preserves native surfaces");
            window.resize(1000,600);settle();
            check(preview->geometry()==initialPreviewRect && program->geometry()==initialProgramRect,"exact baseline geometry restored");
            app.setStyleSheet(qss);frames.refresh();settle();
            delete observer.data();delete program;delete programHost;frames.refresh();settle();check(frames.panelCount()==1,"Program teardown pruned safely");
            createProgram();settle();const WId replacementId=program->winId();frames.refresh();settle();
            check(frames.panelCount()==2 && program->winId()==replacementId && program->surfaceDestroyed==0,"Studio Mode recreated Program safely");
            app.setStyleSheet(largeQss);frames.refresh();settle();window.grab().save(output+"/native-frames-large.png");
            check(preview->winId()==previewId && preview->surfaceDestroyed==0 && program->surfaceDestroyed==0,"larger font theme preserves surfaces");
            frames.restore();settle();check(frames.panelCount()==0,"shutdown restoration");
            frames.restore();settle();check(window.contentsMargins()==mainBaseline,"repeat restore is idempotent");
            delete keeper;
            frontendWindow=&window;
            check(supportedRuntime("32.2.2","6.11.1") && !supportedRuntime("32.2.2","6.12.0") && !supportedRuntime("33.0.0","6.11.1"),"accepted and rejected runtime pairs");
            runtimeObsVersion="33.0.0";check(!obs_module_load() && !registeredCallback,"unsupported runtime does not register");runtimeObsVersion="32.2.2";
            check(obs_module_load() && registeredCallback,"public module load registers callback");
            registeredCallback(OBS_FRONTEND_EVENT_FINISHED_LOADING,nullptr);settle();
            check(previewHost->findChild<QFrame *>("nrcPreviewFrame"),"finished loading event applies frame");
            registeredCallback(OBS_FRONTEND_EVENT_THEME_CHANGED,nullptr);
            registeredCallback(OBS_FRONTEND_EVENT_EXIT,nullptr);registeredCallback=nullptr;settle();
            check(!previewHost->findChild<QFrame *>("nrcPreviewFrame") && previewHost->contentsMargins()==QMargins(),"EXIT cancels queued theme work and restores geometry");
            obs_module_unload();settle();
            check(obs_module_load() && registeredCallback,"module reload in isolated fixture");
            registeredCallback(OBS_FRONTEND_EVENT_STUDIO_MODE_ENABLED,nullptr);settle();
            registeredCallback(OBS_FRONTEND_EVENT_STUDIO_MODE_DISABLED,nullptr);obs_module_unload();settle();
            check(!registeredCallback && !previewHost->findChild<QFrame *>("nrcPreviewFrame"),"unload unregisters and cancels queued work");
            auto *temporaryWindow=new QWidget;frontendWindow=temporaryWindow;
            check(obs_module_load(),"parent teardown fixture load");
            registeredCallback(OBS_FRONTEND_EVENT_FINISHED_LOADING,nullptr);delete temporaryWindow;settle();obs_module_unload();
            check(!registeredCallback,"main-window destruction guards queued refresh");frontendWindow=&window;
            check(preview->winId()==previewId && program->winId()==replacementId && preview->surfaceDestroyed==0 && program->surfaceDestroyed==0,"event bridge preserves original native surfaces");
            auto *finalFrames=new PanelFrames(&window);
            app.setStyleSheet(qss);finalFrames->refresh();settle();
            window.grab().save(output+"/native-frames-final.png");
            result["passed"]=true;
            result["native_surface_destructions"]=preview->surfaceDestroyed+program->surfaceDestroyed;
            result["checks"]=QString("same native parents, handles and layout items; matching properties; rounded frame pixels; complete Preview controls; repeat apply; resize; baseline restoration; Program recreation; larger fonts; upstream size observer; horizontal/vertical; hidden display/title; accepted/rejected runtime; module load/event/EXIT/unload; queued parent teardown");
            result["limitation"]="Native QWidget fixture, not live OBS GPU rendering. OBS activation requires the next launch.";
        } catch(const std::exception &e) {result["passed"]=false;result["error"]=e.what();}
        QFile report(output+"/native-lifecycle.json");
        if (report.open(QIODevice::WriteOnly)) report.write(QJsonDocument(result).toJson());
        window.setWindowTitle(result["passed"].toBool()?"Panel Frame Check — passed":"Panel Frame Check — failed");
    });
    return app.exec();
}
#include "native-fixture.moc"
