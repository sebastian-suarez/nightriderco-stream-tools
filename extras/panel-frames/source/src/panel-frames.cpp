#include "panel-frames.hpp"
#include <QApplication>
#include <QEvent>
#include <QLabel>
#include <QMetaProperty>
#include <algorithm>

PanelFrames::PanelFrames(QWidget *window) : QObject(window), main(window)
{
    refreshTimer.setSingleShot(true);
    geometryTimer.setSingleShot(true);
    connect(&refreshTimer, &QTimer::timeout, this, [this] { reconcile(); });
    connect(&geometryTimer, &QTimer::timeout, this, [this] { updateFrames(); });
}

PanelFrames::~PanelFrames() { restore(); }

void PanelFrames::refresh() { refreshTimer.start(0); }

int PanelFrames::panelCount() const
{
    return int(std::count_if(panels.begin(), panels.end(), [](const Panel &p) {
        return p.host && p.display && p.frame;
    }));
}

void PanelFrames::refreshColor(QWidget *display)
{
    const int index = display->metaObject()->indexOfProperty("displayBackgroundColor");
    if (index < 0) return;
    const QMetaProperty property = display->metaObject()->property(index);
    if (!property.isWritable() || property.metaType() != QMetaType::fromType<QColor>()) return;
    // Force the public setter to refresh a display created after its first style polish.
    property.write(display, QColor("#0b1119"));
    property.write(display, QColor("#0b1118"));
}

void PanelFrames::refreshTitleStyle(QWidget *title)
{
    // A local stylesheet reset invalidates Qt's cached property selector rules.
    const QString original = title->styleSheet();
    title->setStyleSheet(original + '\n');
    title->setStyleSheet(original);
    title->updateGeometry();
    title->update();
}

void PanelFrames::updateMainInset(bool enabled, QWidget *canvas)
{
    if (!enabled) {
        if (main && mainInsetApplied) {
            const QMargins m = main->contentsMargins();
            main->setContentsMargins(m.left(), std::max(0, m.top() - mainTopInset), m.right(), m.bottom());
        }
        mainInsetApplied = false;
        for (Title &title : titles) {
            if (!title.widget) continue;
            title.widget->setProperty("nrcMainWindowInset", title.previousInsetProperty);
            refreshTitleStyle(title.widget);
        }
        titles.clear();
        return;
    }
    if (!main || !canvas) return;
    if (!mainInsetApplied) {
        const QMargins m = main->contentsMargins();
        main->setContentsMargins(m.left(), m.top() + mainTopInset, m.right(), m.bottom());
        mainInsetApplied = true;
    }
    titles.erase(std::remove_if(titles.begin(), titles.end(), [](const Title &title) {
        return !title.widget;
    }), titles.end());
    for (QLabel *label : canvas->findChildren<QLabel *>()) {
        if (!label->property("class").toString().split(' ').contains("label-preview-title")) continue;
        const auto found = std::find_if(titles.begin(), titles.end(), [label](const Title &title) {
            return title.widget == label;
        });
        if (found == titles.end()) {
            titles.push_back({label, label->property("nrcMainWindowInset")});
            label->setProperty("nrcMainWindowInset", true);
        }
        refreshTitleStyle(label);
    }
}

void PanelFrames::reconcile()
{
    if (!main || !qApp->styleSheet().contains("#nrcPreviewFrame")) {
        restore();
        return;
    }
    panels.erase(std::remove_if(panels.begin(), panels.end(), [](const Panel &p) {
        return !p.host;
    }), panels.end());
    QWidget *canvas = main->findChild<QWidget *>("canvasEditor");
    updateMainInset(qApp->styleSheet().contains("nrcMainWindowInset"), canvas);
    if (!canvas) return;
    const auto hosts = canvas->findChildren<QWidget *>(QString(), Qt::FindDirectChildrenOnly);
    for (QWidget *host : hosts) {
        const bool preview = host->objectName() == "previewContainer";
        if (!preview && !host->objectName().isEmpty()) continue;
        QWidget *display = nullptr;
        for (QWidget *child : host->findChildren<QWidget *>(QString(), Qt::FindDirectChildrenOnly)) {
            if (child->inherits("OBSQTDisplay") &&
                ((preview && child->objectName() == "preview") ||
                 (!preview && child->objectName().isEmpty()))) {
                if (display) { display = nullptr; break; }
                display = child;
            }
        }
        if (!display) continue;
        bool hasTitle = false;
        for (QLabel *label : host->findChildren<QLabel *>(QString(), Qt::FindDirectChildrenOnly)) {
            if (label->property("class").toString().split(' ').contains("label-preview-title"))
                hasTitle = true;
        }
        if (!hasTitle) continue;
        const auto existing = std::find_if(panels.begin(), panels.end(), [host](const Panel &p) {
            return p.host == host;
        });
        if (existing != panels.end() || addPanel(host, display, preview)) refreshColor(display);
    }
    geometryTimer.start(0);
}

bool PanelFrames::addPanel(QWidget *host, QWidget *display, bool preview)
{
    if (!host->layout()) return false;
    Panel panel;
    panel.host = host;
    panel.display = display;
    panel.originalMargins = host->contentsMargins();
    if (preview) {
        for (QGridLayout *grid : host->findChildren<QGridLayout *>()) {
            const int index = grid->indexOf(display);
            if (index < 0) continue;
            int row, col, rows, cols;
            grid->getItemPosition(index, &row, &col, &rows, &cols);
            if (row != 1 || col != 0 || rows != 1 || cols != 2) return false;
            for (int c = 0; c < grid->columnCount(); ++c)
                if (grid->itemAtPosition(0, c)) return false;
            panel.grid = grid;
            panel.originalRowHeight = grid->rowMinimumHeight(0);
            break;
        }
        if (!panel.grid) return false;
    } else {
        panel.box = qobject_cast<QVBoxLayout *>(host->layout());
        if (!panel.box || panel.box->indexOf(display) < 1) return false;
    }

    // The native display's parent and layout item are deliberately untouched.
    auto *frame = new QFrame(host);
    frame->setObjectName(preview ? "nrcPreviewFrame" : "nrcProgramFrame");
    frame->setAttribute(Qt::WA_TransparentForMouseEvents);
    frame->setFocusPolicy(Qt::NoFocus);
    frame->lower();
    panel.frame = frame;
    if (panel.grid) {
        panel.grid->setRowMinimumHeight(0, panel.originalRowHeight + inset);
    } else {
        panel.spacer = new QSpacerItem(0, inset, QSizePolicy::Minimum, QSizePolicy::Fixed);
        panel.box->insertSpacerItem(panel.box->indexOf(display), panel.spacer);
    }
    const QMargins m = panel.originalMargins;
    host->setContentsMargins(m.left() + inset, m.top(), m.right() + inset, m.bottom() + inset);
    host->installEventFilter(this);
    display->installEventFilter(this);
    panels.push_back(panel);
    return true;
}

void PanelFrames::updateFrames()
{
    for (Panel &p : panels) {
        if (!p.host || !p.display || !p.frame) continue;
        const QRect content = p.host->rect().marginsRemoved(p.originalMargins);
        const int top = std::max(content.top(), p.display->y() - inset);
        const QRect frameRect(content.left(), top, content.width(), content.bottom() - top + 1);
        p.frame->setGeometry(frameRect);
        p.frame->lower();
        p.frame->setVisible(!p.display->isHidden());
    }
}

bool PanelFrames::eventFilter(QObject *, QEvent *event)
{
    switch (event->type()) {
    case QEvent::Resize:
    case QEvent::Move:
    case QEvent::LayoutRequest:
    case QEvent::Show:
    case QEvent::Hide:
        geometryTimer.start(0);
        break;
    default: break;
    }
    return false;
}

void PanelFrames::restore()
{
    refreshTimer.stop();
    geometryTimer.stop();
    updateMainInset(false);
    for (Panel &p : panels) {
        if (!p.host) continue;
        p.host->removeEventFilter(this);
        if (p.display) p.display->removeEventFilter(this);
        const QMargins now = p.host->contentsMargins();
        // Preserve unrelated later margin changes while removing this extension's inset.
        p.host->setContentsMargins(std::max(0, now.left() - inset), now.top(),
                                  std::max(0, now.right() - inset), std::max(0, now.bottom() - inset));
        if (p.grid) p.grid->setRowMinimumHeight(0, std::max(0, p.grid->rowMinimumHeight(0) - inset));
        if (p.box && p.spacer) {
            for (int i = 0; i < p.box->count(); ++i) {
                if (p.box->itemAt(i) == p.spacer) {
                    p.box->removeItem(p.spacer);
                    delete p.spacer;
                    break;
                }
            }
        }
        delete p.frame.data();
    }
    panels.clear();
}
